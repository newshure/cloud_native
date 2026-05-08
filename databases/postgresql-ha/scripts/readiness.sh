#!/bin/bash
# =============================================================================
# Read 가용성 우선 readiness
# - streaming 여부는 보지 않는다.
# - 이유: failover 중에도 read endpoint 를 최대한 유지하기 위함
# =============================================================================
set -e
# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

"${POSTGRESQL_BIN_DIR}/pg_isready" -h "${POSTGRESQL_SOCKET_DIR}" -p "${POSTGRESQL_PORT}" -t 3 >/dev/null 2>&1
"${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -At -c "SELECT 1" >/dev/null 2>&1
