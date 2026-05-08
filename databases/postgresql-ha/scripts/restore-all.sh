#!/bin/bash
# =============================================================================
# 최종 수동 복구용 전체 복원 스크립트
#
# 사용 시점
# - 자동 복구(pg_rewind / pg_basebackup)로 해결되지 않을 때
# - maintainer 가 신규 Primary 를 깨끗하게 초기화한 뒤 전체 복원을 수행할 때
#
# 입력
#   restore-all.sh <backup_root_or_scheduled_dir>
#
# 동작
# 1) 가장 최신 manifest 선택
# 2) globals 복원
# 3) manifest 에 기록된 DB 목록 순서대로 복원
# =============================================================================
set -euo pipefail
# shellcheck disable=SC2034
SCRIPT_NAME="restore-all"

# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <backup_root_or_scheduled_dir>"
  exit 2
fi

INPUT_DIR="$1"
if [[ -d "${INPUT_DIR}/scheduled" ]]; then
  SCHED_DIR="${INPUT_DIR}/scheduled"
elif [[ -d "$INPUT_DIR" ]]; then
  SCHED_DIR="$INPUT_DIR"
else
  log "오류: 백업 디렉터리를 찾을 수 없습니다."
  exit 1
fi

manifest=$(find "${SCHED_DIR}" -maxdepth 1 -type f -name '*_manifest_*.txt' | sort | tail -1 || true)
if [[ -z "$manifest" ]]; then
  log "오류: manifest 파일이 없습니다."
  exit 1
fi

ts=$(basename "$manifest" | sed -E 's/.*_manifest_([0-9]{8}_[0-9]{6})\.txt/\1/')
globals=$(find "${SCHED_DIR}" -maxdepth 1 -type f -name "*_globals_${ts}.sql" | sort | head -1 || true)

if [[ -z "$globals" ]]; then
  log "오류: globals 백업 파일이 없습니다."
  exit 1
fi

log "복원 기준 시각: ${ts}"
log "globals 복원 시작"
"${POSTGRESQL_BIN_DIR}/psql" -h "${POSTGRESQL_SOCKET_DIR}" -U "${POSTGRESQL_SUPERUSER}" -d postgres -f "$globals"

while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  dump=$(find "${SCHED_DIR}" -maxdepth 1 -type f -name "*_${db}_${ts}.dump" | sort | head -1 || true)
  if [[ -z "$dump" ]]; then
    log "경고: ${db} dump 파일이 없어서 건너뜁니다."
    continue
  fi

  log "DB 복원 준비: ${db}"
  "${POSTGRESQL_BIN_DIR}/psql" -h "${POSTGRESQL_SOCKET_DIR}" -U "${POSTGRESQL_SUPERUSER}" -d postgres -v ON_ERROR_STOP=1 <<EOSQL
SELECT 'CREATE DATABASE "${db}"' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${db}')\gexec
EOSQL

  log "DB 복원 실행: ${db}"
  "${POSTGRESQL_BIN_DIR}/pg_restore" -h "${POSTGRESQL_SOCKET_DIR}" -U "${POSTGRESQL_SUPERUSER}" -d "$db" "$dump"
done < "$manifest"

log "전체 복원 완료"
