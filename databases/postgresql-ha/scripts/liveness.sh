#!/bin/bash
# =============================================================================
# 최소 liveness
# - 과도한 검사로 불필요한 재시작을 유발하지 않도록 단순 유지
# =============================================================================
set -e
# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

"${POSTGRESQL_BIN_DIR}/pg_isready" -h "${POSTGRESQL_SOCKET_DIR}" -p "${POSTGRESQL_PORT}" -t 3 >/dev/null 2>&1
