#!/bin/bash
# =============================================================================
# PostgreSQL 메인 컨테이너 진입점
# - 책임은 최대한 단순하게 유지
# - init-ha-bootstrap 이 PGDATA 를 준비했는지만 확인
# - 준비가 끝났으면 postgres 프로세스만 실행
# =============================================================================
set -e
# shellcheck disable=SC2034
SCRIPT_NAME="entrypoint"

# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

log "PGDATA 경로: ${POSTGRESQL_DATA_DIR}"
if [[ ! -s "${POSTGRESQL_DATA_DIR}/PG_VERSION" ]]; then
  log "오류: PGDATA 가 초기화되지 않았습니다. init-ha-bootstrap 완료 여부를 확인하세요."
  exit 1
fi

log "postgres 프로세스를 시작합니다."
exec "${POSTGRESQL_BIN_DIR}/postgres" \
  -D "${POSTGRESQL_DATA_DIR}" \
  -c config_file="${POSTGRESQL_DATA_DIR}/postgresql.conf" \
  -c hba_file="${POSTGRESQL_DATA_DIR}/pg_hba.conf" \
  -c ident_file="${POSTGRESQL_DATA_DIR}/pg_ident.conf" \
  -c listen_addresses="${POSTGRESQL_LISTEN_ADDRESS}" \
  -c port="${POSTGRESQL_PORT}"
