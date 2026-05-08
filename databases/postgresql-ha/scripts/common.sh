#!/bin/bash
# =============================================================================
# 공통 함수 모음
# - StatefulSet 에서 주입하는 환경변수를 기본값과 함께 정리
# - init / main / role-manager / backup / prestop 가 공통 사용
# =============================================================================

pg_set_env() {
  export POSTGRESQL_VERSION="${POSTGRESQL_VERSION:-16}"
  export POSTGRESQL_BIN_DIR="${POSTGRESQL_BIN_DIR:-/opt/postgresql/bin}"
  export POSTGRESQL_CONF_DIR="${POSTGRESQL_CONF_DIR:-/opt/postgresql/conf}"
  export POSTGRESQL_DATA_DIR="${POSTGRESQL_DATA_DIR:-/opt/postgresql/data}"
  export POSTGRESQL_BACKUP_DIR="${POSTGRESQL_BACKUP_DIR:-/opt/postgresql/backup}"
  export POSTGRESQL_LOG_DIR="${POSTGRESQL_LOG_DIR:-/var/log/postgresql}"
  export POSTGRESQL_SOCKET_DIR="${POSTGRESQL_SOCKET_DIR:-/var/run/postgresql}"
  export POSTGRESQL_ENCODING="${POSTGRESQL_ENCODING:-UTF-8}"
  export POSTGRESQL_LOCALE="${POSTGRESQL_LOCALE:-ko_KR.UTF-8}"
  export POSTGRESQL_PORT="${POSTGRESQL_PORT:-5432}"
  export POSTGRESQL_LISTEN_ADDRESS="${POSTGRESQL_LISTEN_ADDRESS:-*}"
  export POSTGRESQL_SUPERUSER="${POSTGRESQL_SUPERUSER:-postgres}"
  export POSTGRESQL_REPLICATION_USER="${POSTGRESQL_REPLICATION_USER:-postgres}"
  export POSTGRESQL_REPLICAS="${POSTGRESQL_REPLICAS:-2}"
  export POSTGRESQL_STS_NAME="${POSTGRESQL_STS_NAME:-postgresql}"
  export POSTGRESQL_HEADLESS_SVC_NAME="${POSTGRESQL_HEADLESS_SVC_NAME:-postgresql-headless-service}"
  export POSTGRESQL_LEASE_NAME="${POSTGRESQL_LEASE_NAME:-postgres-primary-lease}"
  export POSTGRESQL_LEASE_DURATION_SEC="${POSTGRESQL_LEASE_DURATION_SEC:-30}"
  export POSTGRESQL_MASTER_LABEL_VALUE="${POSTGRESQL_MASTER_LABEL_VALUE:-master}"
  export POSTGRESQL_SYNC_NAMES="${POSTGRESQL_SYNC_NAMES:-ANY 1 (postgresql-0,postgresql-1)}"
  export POSTGRESQL_ROLE_MGR_LOOP_SEC="${POSTGRESQL_ROLE_MGR_LOOP_SEC:-5}"
  export POSTGRESQL_PEER_FAIL_THRESHOLD="${POSTGRESQL_PEER_FAIL_THRESHOLD:-3}"
  export POSTGRESQL_ISOLATION_THRESHOLD="${POSTGRESQL_ISOLATION_THRESHOLD:-3}"
  export POSTGRESQL_RENEW_FAIL_THRESHOLD="${POSTGRESQL_RENEW_FAIL_THRESHOLD:-3}"
  export POSTGRESQL_PEER_WAIT_SEC="${POSTGRESQL_PEER_WAIT_SEC:-600}"
  export POSTGRESQL_BACKUP_RETENTION_DAYS="${POSTGRESQL_BACKUP_RETENTION_DAYS:-56}"
  export POSTGRESQL_BACKUP_SCHEDULE_DOW="${POSTGRESQL_BACKUP_SCHEDULE_DOW:-6}"
  export POSTGRESQL_BACKUP_SCHEDULE_HOUR="${POSTGRESQL_BACKUP_SCHEDULE_HOUR:-2}"
  export POSTGRESQL_BACKUP_COMPRESSION_LEVEL="${POSTGRESQL_BACKUP_COMPRESSION_LEVEL:-6}"

  export POD_NAME="${POD_NAME:-${HOSTNAME:-postgresql-0}}"
  export POD_NAMESPACE="${POD_NAMESPACE:-default}"
  export POSTGRESQL_ORDINAL="${POD_NAME##*-}"
  export POSTGRESQL_PEER_ORDINAL=$(( (POSTGRESQL_ORDINAL + 1) % POSTGRESQL_REPLICAS ))
  export POSTGRESQL_PEER_HOST="${POSTGRESQL_STS_NAME}-${POSTGRESQL_PEER_ORDINAL}.${POSTGRESQL_HEADLESS_SVC_NAME}.${POD_NAMESPACE}.svc.cluster.local"
  export POSTGRESQL_SLOT_NAME="${POD_NAME//-/_}_slot"

  export K8S_API="${K8S_API:-https://kubernetes.default.svc}"
  export K8S_SA_DIR="${K8S_SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}"
  export K8S_CA="${K8S_SA_DIR}/ca.crt"
  export LEASE_PATH="/apis/coordination.k8s.io/v1/namespaces/${POD_NAMESPACE}/leases/${POSTGRESQL_LEASE_NAME}"
  export POD_PATH="/api/v1/namespaces/${POD_NAMESPACE}/pods/${POD_NAME}"
}

log() {
  local prefix="${SCRIPT_NAME:-postgresql}"
  echo "[${prefix}-$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

k8s_token() {
  cat "${K8S_SA_DIR}/token" 2>/dev/null
}

k8s_get() {
  local path="$1" tmpfile code
  tmpfile=$(mktemp /tmp/k8s-get.XXXXXX 2>/dev/null) || return 1
  code=$(curl -sS --cacert "${K8S_CA}" --max-time 5 \
    -H "Authorization: Bearer $(k8s_token)" \
    -H "Accept: application/json" \
    -o "$tmpfile" -w "%{http_code}" \
    "${K8S_API}${path}" 2>/dev/null) || code="000"
  if [[ "$code" == "200" ]]; then
    cat "$tmpfile"
    rm -f "$tmpfile"
    return 0
  fi
  rm -f "$tmpfile"
  return 1
}

k8s_put() {
  local path="$1" body="$2" tmpfile code
  tmpfile=$(mktemp /tmp/k8s-put.XXXXXX 2>/dev/null) || { echo "000"; return; }
  code=$(curl -sS --cacert "${K8S_CA}" --max-time 10 -X PUT \
    -H "Authorization: Bearer $(k8s_token)" \
    -H "Content-Type: application/json" \
    -d "$body" \
    -o "$tmpfile" -w "%{http_code}" \
    "${K8S_API}${path}" 2>/dev/null) || code="000"
  rm -f "$tmpfile"
  echo "$code"
}

k8s_post() {
  local path="$1" body="$2" tmpfile code
  tmpfile=$(mktemp /tmp/k8s-post.XXXXXX 2>/dev/null) || { echo "000"; return; }
  code=$(curl -sS --cacert "${K8S_CA}" --max-time 10 -X POST \
    -H "Authorization: Bearer $(k8s_token)" \
    -H "Content-Type: application/json" \
    -d "$body" \
    -o "$tmpfile" -w "%{http_code}" \
    "${K8S_API}${path}" 2>/dev/null) || code="000"
  rm -f "$tmpfile"
  echo "$code"
}

k8s_patch_strategic() {
  local path="$1" body="$2" tmpfile code
  tmpfile=$(mktemp /tmp/k8s-patch.XXXXXX 2>/dev/null) || { echo "000"; return; }
  code=$(curl -sS --cacert "${K8S_CA}" --max-time 5 -X PATCH \
    -H "Authorization: Bearer $(k8s_token)" \
    -H "Content-Type: application/strategic-merge-patch+json" \
    -d "$body" \
    -o "$tmpfile" -w "%{http_code}" \
    "${K8S_API}${path}" 2>/dev/null) || code="000"
  rm -f "$tmpfile"
  echo "$code"
}

api_reachable() {
  curl -sS --cacert "${K8S_CA}" --max-time 3 \
    -H "Authorization: Bearer $(k8s_token)" \
    -o /dev/null "${K8S_API}/healthz" >/dev/null 2>&1
}

ensure_lease_exists() {
  local code body
  code=$(curl -sS --cacert "${K8S_CA}" --max-time 3 \
    -H "Authorization: Bearer $(k8s_token)" \
    -o /dev/null -w "%{http_code}" \
    "${K8S_API}${LEASE_PATH}" 2>/dev/null) || code="000"

  if [[ "$code" == "404" ]]; then
    log "Lease 가 없어서 생성합니다."
    body=$(jq -n --arg n "${POSTGRESQL_LEASE_NAME}" --argjson d "${POSTGRESQL_LEASE_DURATION_SEC}" \
      '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",metadata:{name:$n},spec:{leaseDurationSeconds:$d}}' 2>/dev/null)
    k8s_post "/apis/coordination.k8s.io/v1/namespaces/${POD_NAMESPACE}/leases" "$body" >/dev/null
  fi
}

get_lease_holder() {
  local lease_json
  lease_json=$(k8s_get "${LEASE_PATH}") || return 1
  echo "$lease_json" | jq -r '.spec.holderIdentity // ""' 2>/dev/null || echo ""
}

renew_lease() {
  ensure_lease_exists
  local lease_json holder now body code
  lease_json=$(k8s_get "${LEASE_PATH}") || return 1
  holder=$(echo "$lease_json" | jq -r '.spec.holderIdentity // ""' 2>/dev/null || echo "")
  if [[ "$holder" != "$POD_NAME" ]]; then
    log "Lease 갱신 중단: 현재 holder=${holder:-<empty>}"
    return 1
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)
  body=$(echo "$lease_json" | jq --arg t "$now" '.spec.renewTime=$t' 2>/dev/null)
  [[ -z "$body" ]] && return 1
  code=$(k8s_put "${LEASE_PATH}" "$body")
  [[ "$code" == "200" || "$code" == "201" ]]
}

try_take_lease() {
  ensure_lease_exists
  local attempt lease_json holder renew renew_epoch now_epoch now body code
  for attempt in 1 2 3; do
    lease_json=$(k8s_get "${LEASE_PATH}") || { sleep 1; continue; }
    holder=$(echo "$lease_json" | jq -r '.spec.holderIdentity // ""' 2>/dev/null || echo "")
    renew=$(echo "$lease_json" | jq -r '.spec.renewTime // ""' 2>/dev/null || echo "")

    if [[ "$holder" == "$POD_NAME" ]]; then
      return 0
    fi

    if [[ -n "$holder" && "$holder" != "null" && -n "$renew" && "$renew" != "null" ]]; then
      renew_epoch=$(date -u -d "$renew" +%s 2>/dev/null || echo 0)
      now_epoch=$(date -u +%s)
      if (( now_epoch - renew_epoch < POSTGRESQL_LEASE_DURATION_SEC )); then
        return 1
      fi
    fi

    now=$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)
    body=$(echo "$lease_json" | jq \
      --arg h "$POD_NAME" \
      --arg t "$now" \
      --argjson d "$POSTGRESQL_LEASE_DURATION_SEC" \
      '.spec.holderIdentity=$h | .spec.acquireTime=$t | .spec.renewTime=$t | .spec.leaseDurationSeconds=$d' 2>/dev/null)
    [[ -z "$body" ]] && { sleep 1; continue; }

    code=$(k8s_put "${LEASE_PATH}" "$body")
    case "$code" in
      200|201) return 0 ;;
      409) log "Lease CAS 충돌 - 재시도 ${attempt}" ; sleep 1 ;;
      401|403) log "Lease 권한 오류 HTTP ${code}" ; return 1 ;;
      000) log "Lease 연결 오류 - 재시도 ${attempt}" ; sleep 1 ;;
      *) log "Lease 획득 실패 HTTP ${code}" ; return 1 ;;
    esac
  done
  return 1
}

local_pg_ready() {
  "${POSTGRESQL_BIN_DIR}/pg_isready" -h "${POSTGRESQL_SOCKET_DIR}" -p "${POSTGRESQL_PORT}" -t 3 >/dev/null 2>&1
}

peer_pg_reachable() {
  "${POSTGRESQL_BIN_DIR}/pg_isready" -h "${POSTGRESQL_PEER_HOST}" -p "${POSTGRESQL_PORT}" -t 3 >/dev/null 2>&1
}

am_i_primary() {
  local value
  value=$("${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -At -c "SELECT pg_is_in_recovery()" 2>/dev/null)
  [[ "$value" == "f" ]]
}

peer_streaming_ok() {
  "${POSTGRESQL_BIN_DIR}/psql" -U "${POSTGRESQL_SUPERUSER}" -h "${POSTGRESQL_SOCKET_DIR}" -At -c \
    "SELECT 1 FROM pg_stat_replication WHERE state='streaming' LIMIT 1" 2>/dev/null | grep -q 1
}

copy_configs_to_pgdata() {
  local f
  log "설정 파일을 PGDATA 로 복사합니다."
  for f in postgresql.conf pg_hba.conf pg_ident.conf; do
    if [[ -f "${POSTGRESQL_CONF_DIR}/${f}" ]]; then
      cp -f "${POSTGRESQL_CONF_DIR}/${f}" "${POSTGRESQL_DATA_DIR}/${f}"
      chmod 0600 "${POSTGRESQL_DATA_DIR}/${f}"
    else
      log "경고: ${POSTGRESQL_CONF_DIR}/${f} 파일이 없습니다."
    fi
  done
}
