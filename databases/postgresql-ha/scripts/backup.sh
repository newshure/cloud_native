#!/bin/bash
# =============================================================================
# 정기 백업 및 catch-up 백업
# - globals: pg_dumpall --globals-only
# - DB별:   pg_dump -Fc
# - manifest 파일을 남겨서 restore-all.sh 가 같은 시점 데이터를 쉽게 찾게 함
# =============================================================================
set -uo pipefail
# shellcheck disable=SC2034
SCRIPT_NAME="backup"

# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

BACKUP_ROOT="${POSTGRESQL_BACKUP_DIR}/${POD_NAME}"
SCHED_DIR="${BACKUP_ROOT}/scheduled"
MARKER="${BACKUP_ROOT}/.last_scheduled_success"
LOCK_FILE="${BACKUP_ROOT}/.lock"
mkdir -p "$SCHED_DIR"

last_sched_epoch() {
  local now_epoch dow days_back target_epoch
  now_epoch=$(date +%s)
  dow=$(date +%u)
  days_back=$(( (dow - POSTGRESQL_BACKUP_SCHEDULE_DOW + 7) % 7 ))
  target_epoch=$(date -d "today ${POSTGRESQL_BACKUP_SCHEDULE_HOUR}:00 ${days_back} days ago" +%s 2>/dev/null || echo 0)
  if (( target_epoch == 0 || target_epoch > now_epoch )); then
    target_epoch=$(( target_epoch - 7 * 86400 ))
  fi
  echo "$target_epoch"
}

do_dump() {
  local trigger="$1" mark_ts="${2:-}"
  local ts manifest dbs db
  ts=$(date +%Y%m%d_%H%M%S)
  manifest="${SCHED_DIR}/${POD_NAME}_manifest_${ts}.txt"

  log "백업 시작 trigger=${trigger}"

  "${POSTGRESQL_BIN_DIR}/pg_dumpall" --globals-only \
    -h "${POSTGRESQL_SOCKET_DIR}" -U "${POSTGRESQL_SUPERUSER}" \
    > "${SCHED_DIR}/${POD_NAME}_globals_${ts}.sql" 2>/tmp/backup.err \
    || { log "오류: globals 백업 실패 - $(cat /tmp/backup.err)"; return 1; }

  dbs=$("${POSTGRESQL_BIN_DIR}/psql" -h "${POSTGRESQL_SOCKET_DIR}" -U "${POSTGRESQL_SUPERUSER}" -At -c \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres' ORDER BY datname" 2>/dev/null)

  : > "$manifest"
  for db in $dbs; do
    echo "$db" >> "$manifest"
    log "DB 백업: ${db}"
    "${POSTGRESQL_BIN_DIR}/pg_dump" -Fc -Z "${POSTGRESQL_BACKUP_COMPRESSION_LEVEL}" \
      -h "${POSTGRESQL_SOCKET_DIR}" -U "${POSTGRESQL_SUPERUSER}" -d "$db" \
      -f "${SCHED_DIR}/${POD_NAME}_${db}_${ts}.dump" 2>/tmp/backup.err \
      || { log "오류: ${db} 백업 실패 - $(cat /tmp/backup.err)"; return 1; }
  done

  if [[ -n "$mark_ts" ]]; then
    echo "$mark_ts" > "$MARKER"
  else
    date +%s > "$MARKER"
  fi

  find "$SCHED_DIR" -type f \( -name "*.dump" -o -name "*.sql" -o -name "*_manifest_*.txt" \) \
    -mtime "+${POSTGRESQL_BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true

  log "백업 완료"
}

cmd="${1:-run}"
case "$cmd" in
  startup-check)
    for _ in {1..60}; do
      "${POSTGRESQL_BIN_DIR}/pg_isready" -h "${POSTGRESQL_SOCKET_DIR}" -p "${POSTGRESQL_PORT}" -t 2 >/dev/null 2>&1 && break
      sleep 5
    done

    if ! "${POSTGRESQL_BIN_DIR}/pg_isready" -h "${POSTGRESQL_SOCKET_DIR}" -p "${POSTGRESQL_PORT}" -t 2 >/dev/null 2>&1; then
      log "5분 내 postgres 준비 실패 - catch-up 건너뜀"
      exit 0
    fi

    last_sched=$(last_sched_epoch)
    last_ok=$(cat "$MARKER" 2>/dev/null || echo 0)
    log "last_sched=${last_sched}, last_ok=${last_ok}"
    if (( last_ok < last_sched )); then
      flock -n "$LOCK_FILE" -c "$0 _exec catchup $last_sched" || log "다른 백업이 실행 중입니다."
    else
      log "누락 백업 없음"
    fi
    ;;
  run)
    flock -n "$LOCK_FILE" -c "$0 _exec scheduled" || log "다른 백업이 실행 중입니다."
    ;;
  _exec)
    do_dump "$2" "${3:-}"
    ;;
  *)
    echo "usage: $0 {startup-check|run}"
    exit 2
    ;;
esac
