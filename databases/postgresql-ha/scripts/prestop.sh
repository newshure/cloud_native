#!/bin/bash
# =============================================================================
# 종료 직전 정리
# - Replica 가 내려갈 때 Primary 를 async 로 잠시 전환해서 write block 을 줄임
# - keep read 원칙에 맞게 종료는 빠르게 수행
# =============================================================================
set -uo pipefail
# shellcheck disable=SC2034
SCRIPT_NAME="prestop"

# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

in_recovery=$("${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -At -c "SELECT pg_is_in_recovery()" 2>/dev/null || echo "")
if [[ "$in_recovery" == "t" ]]; then
  log "Replica 종료 감지 - Primary 를 async 로 완화 시도"
  "${POSTGRESQL_BIN_DIR}/psql" -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" \
    -U "${POSTGRESQL_SUPERUSER}" -d postgres -c \
    "ALTER SYSTEM SET synchronous_standby_names=''; SELECT pg_reload_conf();" \
    >/dev/null 2>&1 || true
  sleep 2
fi

log "postgres fast stop 수행"
"${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -m fast -w -t 50 stop || true
