#!/bin/bash
# =============================================================================
# 초기 부팅 / 재부팅 시 PostgreSQL 역할 결정 스크립트
#
# 설계 원칙
# 1) Read 유지 우선: Replica 는 최대한 빨리 다시 붙도록 구성
# 2) 운영자 이해 우선: 분기 이름을 명확히 유지
# 3) 자동 복구 우선: pg_rewind -> 실패 시 pg_basebackup
# 4) 최종 수동 복구: maintainer 가 reset 후 restore-all.sh 사용 가능
# =============================================================================
set -uo pipefail
# shellcheck disable=SC2034
SCRIPT_NAME="ha-bootstrap"

# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

has_pg_traces() {
  local marker
  for marker in PG_VERSION standby.signal recovery.signal postgresql.auto.conf pg_wal pg_xact global base; do
    [[ -e "${POSTGRESQL_DATA_DIR}/${marker}" ]] && return 0
  done
  return 1
}

cleanup_non_pgdata() {
  log "PGDATA 안의 비정상 잔여 파일을 정리합니다."
  find "${POSTGRESQL_DATA_DIR}" -mindepth 1 -delete 2>/dev/null || true
}

wait_for_peer_pg() {
  local timeout="${1:-${POSTGRESQL_PEER_WAIT_SEC}}"
  local elapsed=0
  log "상대 Pod(${POSTGRESQL_PEER_HOST}) 준비를 최대 ${timeout}초까지 대기합니다."
  while (( elapsed < timeout )); do
    if "${POSTGRESQL_BIN_DIR}/psql" \
      -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" \
      -U "${POSTGRESQL_REPLICATION_USER}" -d postgres -At -c "SELECT 1" \
      >/dev/null 2>&1; then
      log "상대 Pod 접속 확인 완료"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log "오류: 상대 Pod 준비 대기 시간이 초과되었습니다."
  return 1
}

init_primary() {
  log "Mode A: 새 Primary 를 초기화합니다."
  "${POSTGRESQL_BIN_DIR}/initdb" \
    -D "${POSTGRESQL_DATA_DIR}" \
    --data-checksums \
    --encoding="${POSTGRESQL_ENCODING}" \
    --locale="${POSTGRESQL_LOCALE}" \
    -U "${POSTGRESQL_SUPERUSER}" \
    || { log "오류: initdb 실패"; return 1; }

  copy_configs_to_pgdata

  log "임시 postgres 를 기동하여 replication slot 을 생성합니다."
  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -l /tmp/init.log -w -t 60 \
    -o "-c config_file=${POSTGRESQL_DATA_DIR}/postgresql.conf -c hba_file=${POSTGRESQL_DATA_DIR}/pg_hba.conf -c ident_file=${POSTGRESQL_DATA_DIR}/pg_ident.conf -c synchronous_standby_names='' -c listen_addresses='localhost'" \
    start || { log "오류: bootstrap postgres 시작 실패"; cat /tmp/init.log 2>/dev/null; return 1; }

  "${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -d postgres -v ON_ERROR_STOP=1 <<'EOSQL'
SELECT pg_create_physical_replication_slot('postgresql_0_slot')
  WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='postgresql_0_slot');
SELECT pg_create_physical_replication_slot('postgresql_1_slot')
  WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='postgresql_1_slot');
EOSQL
  local rc=$?

  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -m fast -w -t 30 stop >/dev/null 2>&1 || true
  return "$rc"
}

basebackup_from_primary() {
  log "Replica 용 basebackup 을 수행합니다."
  cleanup_non_pgdata

  "${POSTGRESQL_BIN_DIR}/psql" \
    -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" \
    -U "${POSTGRESQL_REPLICATION_USER}" -d postgres -c \
    "SELECT pg_create_physical_replication_slot('${POSTGRESQL_SLOT_NAME}', true) WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='${POSTGRESQL_SLOT_NAME}');" \
    >/dev/null 2>&1 || true

  "${POSTGRESQL_BIN_DIR}/pg_basebackup" \
    -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" \
    -U "${POSTGRESQL_REPLICATION_USER}" \
    -D "${POSTGRESQL_DATA_DIR}" -X stream -P -R \
    -S "${POSTGRESQL_SLOT_NAME}" \
    || { log "오류: pg_basebackup 실패"; return 1; }

  if [[ -f "${POSTGRESQL_DATA_DIR}/postgresql.auto.conf" ]] && ! grep -q 'application_name=' "${POSTGRESQL_DATA_DIR}/postgresql.auto.conf"; then
    sed -i "s|primary_conninfo = '|primary_conninfo = 'application_name=${POD_NAME} |" "${POSTGRESQL_DATA_DIR}/postgresql.auto.conf"
  fi

  touch "${POSTGRESQL_DATA_DIR}/standby.signal"
  copy_configs_to_pgdata
  chmod 0700 "${POSTGRESQL_DATA_DIR}" || true
}

resume_primary() {
  log "Primary 로 기동을 재개합니다."
  rm -f "${POSTGRESQL_DATA_DIR}/standby.signal"
  copy_configs_to_pgdata
}

rejoin_as_replica() {
  log "Replica 로 재합류를 시도합니다."
  wait_for_peer_pg "${POSTGRESQL_PEER_WAIT_SEC}" || return 1

  local slot_status
  slot_status=$("${POSTGRESQL_BIN_DIR}/psql" \
    -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" \
    -U "${POSTGRESQL_REPLICATION_USER}" -d postgres -At -c \
    "SELECT COALESCE(invalidation_reason, 'ok') FROM pg_replication_slots WHERE slot_name='${POSTGRESQL_SLOT_NAME}';" \
    2>/dev/null || echo "missing")
  log "slot 상태: ${slot_status}"

  if [[ "$slot_status" != "ok" ]]; then
    log "slot 이 유효하지 않아서 fresh basebackup 으로 전환합니다."
    "${POSTGRESQL_BIN_DIR}/psql" \
      -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" \
      -U "${POSTGRESQL_REPLICATION_USER}" -d postgres -c \
      "SELECT pg_drop_replication_slot('${POSTGRESQL_SLOT_NAME}') WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='${POSTGRESQL_SLOT_NAME}');" \
      >/dev/null 2>&1 || true
    basebackup_from_primary
    return $?
  fi

  copy_configs_to_pgdata

  # pg_rewind 는 대상 cluster 가 clean shutdown 상태여야 성공 확률이 높다.
  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -w -t 30 \
    -o "-c config_file=${POSTGRESQL_DATA_DIR}/postgresql.conf -c hba_file=${POSTGRESQL_DATA_DIR}/pg_hba.conf -c ident_file=${POSTGRESQL_DATA_DIR}/pg_ident.conf -c synchronous_standby_names='' -c listen_addresses='localhost'" \
    start >/dev/null 2>&1 || true
  sleep 3
  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -w -t 30 -m fast stop >/dev/null 2>&1 || true

  if "${POSTGRESQL_BIN_DIR}/pg_rewind" \
      --target-pgdata="${POSTGRESQL_DATA_DIR}" \
      --source-server="host=${POSTGRESQL_PEER_HOST} port=${POSTGRESQL_PORT} user=${POSTGRESQL_REPLICATION_USER} dbname=postgres" \
      --progress; then
    log "pg_rewind 성공"
    cat > "${POSTGRESQL_DATA_DIR}/postgresql.auto.conf" <<EOCONF
primary_conninfo = 'host=${POSTGRESQL_PEER_HOST} port=${POSTGRESQL_PORT} user=${POSTGRESQL_REPLICATION_USER} application_name=${POD_NAME}'
primary_slot_name = '${POSTGRESQL_SLOT_NAME}'
EOCONF
    chmod 0600 "${POSTGRESQL_DATA_DIR}/postgresql.auto.conf"
    touch "${POSTGRESQL_DATA_DIR}/standby.signal"
    copy_configs_to_pgdata
    return 0
  fi

  log "pg_rewind 실패 - fresh basebackup 으로 전환합니다."
  basebackup_from_primary
}

mkdir -p "${POSTGRESQL_LOG_DIR}" 2>/dev/null || true
log "시작: POD=${POD_NAME}, PEER=${POSTGRESQL_PEER_HOST}, SLOT=${POSTGRESQL_SLOT_NAME}"

if [[ -e "${POSTGRESQL_DATA_DIR}/PG_VERSION" ]]; then
  PGDATA_EXISTS=true
  log "기존 PGDATA 가 존재합니다."
else
  PGDATA_EXISTS=false
  if has_pg_traces; then
    log "오류: PG_VERSION 없이 PostgreSQL 흔적이 남아 있습니다. 운영자 확인이 필요합니다."
    find "${POSTGRESQL_DATA_DIR}" -maxdepth 1 -mindepth 1 -printf '%M %u:%g %p\n' 2>/dev/null | head -30
    exit 1
  fi
  cleanup_non_pgdata
fi

HOLDER=$(get_lease_holder 2>/dev/null || echo "")
log "현재 Lease holder: ${HOLDER:-<empty>}"

if [[ "$PGDATA_EXISTS" == "false" ]]; then
  log "첫 기동 분기"
  if try_take_lease; then
    init_primary || exit 1
    copy_configs_to_pgdata
    log "Mode A 완료: Primary 준비 완료"
  else
    wait_for_peer_pg "${POSTGRESQL_PEER_WAIT_SEC}" || exit 1
    basebackup_from_primary || exit 1
    log "Mode B 완료: Replica 준비 완료"
  fi
  exit 0
fi

log "재기동 분기"
if [[ "$HOLDER" == "$POD_NAME" ]]; then
  resume_primary
  log "Mode C 완료: 기존 Primary 재개"
  exit 0
fi

if [[ -z "$HOLDER" || "$HOLDER" == "null" ]]; then
  log "Lease 가 비어 있으므로 재선출을 시도합니다."
  if try_take_lease; then
    resume_primary
    log "Mode E-Primary 완료: 경합 승리"
    exit 0
  fi
fi

rejoin_as_replica || exit 1
log "Mode D/E-Replica 완료: Replica 재합류"
exit 0
