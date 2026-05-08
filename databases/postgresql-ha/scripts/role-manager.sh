#!/bin/bash
# =============================================================================
# Primary / Replica 역할 관리자
# - Lease 유지
# - role=master 라벨 관리
# - sync/async 전환
# - keep read 우선 정책을 깨지 않는 선에서 demote / promote 수행
# =============================================================================
set -uo pipefail
# shellcheck disable=SC2034
SCRIPT_NAME="role-manager"

# shellcheck source=/opt/postgresql/bin/common.sh
source /opt/postgresql/bin/common.sh
pg_set_env

label_self() {
  local role="$1" body code
  if [[ -z "$role" ]]; then
    body=$(jq -n '{metadata:{labels:{role:null}}}' 2>/dev/null)
  else
    body=$(jq -n --arg r "$role" '{metadata:{labels:{role:$r}}}' 2>/dev/null)
  fi
  code=$(k8s_patch_strategic "${POD_PATH}" "$body")
  [[ "$code" == "200" ]] || log "경고: role 라벨 반영 실패 HTTP ${code}"
}

set_sync_mode() {
  local mode="$1" current target
  current=$("${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -At -c "SHOW synchronous_standby_names" 2>/dev/null)
  [[ "$mode" == "sync" ]] && target="${POSTGRESQL_SYNC_NAMES}" || target=""

  if [[ "$current" != "$target" ]]; then
    log "sync 설정 변경: '${current}' -> '${target}'"
    "${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -c \
      "ALTER SYSTEM SET synchronous_standby_names = '$target'; SELECT pg_reload_conf();" \
      >/dev/null 2>&1 || log "경고: sync 설정 변경 실패"
  fi
}

promote_self() {
  log "Replica 를 Primary 로 승격합니다."
  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" promote || true
}

demote_and_exit() {
  local reason="$1"
  log "Demote 수행: ${reason}"
  set_sync_mode async
  label_self ""
  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -m fast stop || true
  exit 1
}

self_fence() {
  log "SELF-FENCE: API 와 peer 모두 접근 불가 - Primary 정지"
  label_self ""
  "${POSTGRESQL_BIN_DIR}/pg_ctl" -D "${POSTGRESQL_DATA_DIR}" -m immediate stop || true
  exit 1
}

peer_fail=0
iso_fail=0
renew_fail=0

log "시작: POD=${POD_NAME}, PEER=${POSTGRESQL_PEER_HOST}"
for _ in {1..60}; do
  local_pg_ready && break
  sleep 2
done
log "local postgres 준비 완료"

while true; do
  if ! local_pg_ready; then
    log "local postgres 준비 안 됨 - 다음 루프에서 재확인"
    sleep "${POSTGRESQL_ROLE_MGR_LOOP_SEC}"
    continue
  fi

  api_ok=no
  peer_ok=no
  api_reachable && api_ok=yes
  peer_pg_reachable && peer_ok=yes

  [[ "$peer_ok" == "no" ]] && peer_fail=$((peer_fail + 1)) || peer_fail=0
  [[ "$api_ok" == "no" && "$peer_ok" == "no" ]] && iso_fail=$((iso_fail + 1)) || iso_fail=0

  role="replica"
  am_i_primary && role="primary"

  if [[ "$role" == "primary" && "$iso_fail" -ge "$POSTGRESQL_ISOLATION_THRESHOLD" ]]; then
    self_fence
  fi

  if [[ "$api_ok" == "no" ]]; then
    sleep "${POSTGRESQL_ROLE_MGR_LOOP_SEC}"
    continue
  fi

  holder=$(get_lease_holder 2>/dev/null || echo "")

  if [[ "$role" == "primary" ]]; then
    if [[ "$holder" == "$POD_NAME" ]]; then
      if renew_lease; then
        renew_fail=0
        label_self "${POSTGRESQL_MASTER_LABEL_VALUE}"
        if peer_streaming_ok; then
          set_sync_mode sync
        elif (( peer_fail >= POSTGRESQL_PEER_FAIL_THRESHOLD )); then
          set_sync_mode async
        fi
      else
        renew_fail=$((renew_fail + 1))
        log "Lease 갱신 실패 ${renew_fail}/${POSTGRESQL_RENEW_FAIL_THRESHOLD}"
        if (( renew_fail >= POSTGRESQL_RENEW_FAIL_THRESHOLD )); then
          demote_and_exit "Lease 갱신 임계치 초과"
        fi
      fi
    else
      demote_and_exit "현재 holder=${holder:-<empty>}"
    fi
  else
    label_self ""
    if [[ -z "$holder" || "$holder" == "null" ]]; then
      log "Lease 비어 있음 - takeover 시도"
      if try_take_lease; then
        promote_self
        sleep 3
      fi
    elif (( peer_fail >= POSTGRESQL_PEER_FAIL_THRESHOLD )) && [[ "$peer_ok" == "no" ]]; then
      log "peer 비정상 ${peer_fail}회 - takeover 시도"
      if try_take_lease; then
        promote_self
        sleep 3
      fi
    fi
  fi

  sleep "${POSTGRESQL_ROLE_MGR_LOOP_SEC}"
done
