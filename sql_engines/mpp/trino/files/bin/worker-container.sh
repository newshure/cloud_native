#!/bin/bash 

set -e

# JAVA_HOME
export JAVA_HOME=${JAVA_HOME:-/lib/jvm/java-25.0.2-openjdk}

# BASIC_ENV
export TRINO_HOME=${TRINO_HOME:-/opt/trino}
export TRINO_CONF_DIR=${TRINO_CONF_DIR:-${TRINO_HOME}/etc}
export TRINO_CONF_TEMPLATES_DIR=${TRINO_CONF_TEMPLATES_DIR:-${TRINO_CONF_DIR}/templates}
export TRINO_CATALOG_DIR=${TRINO_CATALOG_DIR:-${TRINO_CONF_DIR}/catalog}
export TRINO_DATA_DIR=${TRINO_DATA_DIR:-${TRINO_HOME}/data}
export TRINO_SERVER_HTTP_PORT=${TRINO_SERVER_HTTP_PORT:-8080}
export TRINO_SERVER_HTTPS_PORT=${TRINO_SERVER_HTTPS_PORT:-8443}
export TRINO_HTTPS_SERVER_CERT_PATH=${TRINO_HTTPS_SERVER_CERT_PATH:-${TRINO_CONF_DIR}/certs/server.pem}
export TRINO_SERVER_AUTH_TYPE=${TRINO_SERVER_AUTH_TYPE:-PASSWORD}
export TRINO_SERVER_AUTH_FILE=${TRINO_SERVER_AUTH_FILE:-${TRINO_CONF_DIR}/password.db}
export TRINO_LOG_DIR=${TRINO_LOG_DIR:-/var/log/trino}
export TRINO_LAUNCHER_LOG=${TRINO_LAUNCHER_LOG:-${TRINO_LOG_DIR}/trino-launcher.log}
export TRINO_SERVER_LOG=${TRINO_SERVER_LOG:-${TRINO_LOG_DIR}/trino-server.log}
# 운영 환경에서는 K8s Secret 으로 주입하고, 컨테이너에 envFrom 으로 받아오세요.
# 기본값을 두지 않아 미설정 시 즉시 실패하도록 가드.
if [[ -z "${TRINO_INTERNAL_SHARED_SECRET:-}" ]]; then
  echo "ERROR: TRINO_INTERNAL_SHARED_SECRET is not set. Inject via Secret/envFrom." >&2
  exit 1
fi
export TRINO_INTERNAL_SHARED_SECRET
export TRINO_HEAPDUMP_PATH=${TRINO_HEAPDUMP_PATH:-${TRINO_HOME}/dump/${POD_NAME}_$(date +%Y%m%d-%H%M).dmp}
export SPILL_ENABLED=${SPILL_ENABLED:-true}
export SPILL_DIR=${SPILL_DIR:-${TRINO_HOME}/spill}
export SPILL_COMPRESSION_ENABLED=${SPILL_COMPRESSION_ENABLED:-true}
export TRINO_SERVER_DISCOVERY_URI=${TRINO_SERVER_DISCOVERY_URI:-"http://trino-coordinator-service:8080"}

export COORDINATOR_ENABLED=${COORDINATOR_ENABLED:=false}
export WORKER_ENABLED=${WORKER_ENABLED:=true}


# MEMORY_CONF
export JAVA_G1_HEAP_REGION_SIZE=${JAVA_G1_HEAP_REGION_SIZE:-32M}
export RESERVED_CODE_CACHE_SIZE=${RESERVED_CODE_CACHE_SIZE:-512M}
export JAVA_INITIAL_RAM_PERCENTAGE=${JAVA_INITIAL_RAM_PERCENTAGE:-80}
export JAVA_MAX_RAM_PERCENTAGE=${JAVA_MAX_RAM_PERCENTAGE:-80}
export QUERY_MAX_MEMORY_PER_NODE=${QUERY_MAX_MEMORY_PER_NODE:-14GB}
export MEMORY_HEAP_HEADROOM_PER_NODE=${MEMORY_HEAP_HEADROOM_PER_NODE:-512MB}



# envsubst 치환
for f in jvm.config config.properties node.properties log.properties password-authenticator.properties; do
  envsubst < ${TRINO_CONF_TEMPLATES_DIR}/${f}.template > ${TRINO_CONF_DIR}/${f}
done


echo Start trino Coordinator run with command:
echo ${TRINO_HOME}/bin/launcher run
echo              --etc-dir ${TRINO_CONF_DIR} 
echo              --launcher-log-file ${TRINO_LAUNCHER_LOG}
echo              --server-log-file ${TRINO_SERVER_LOG}

cd ${TRINO_HOME}
exec ${TRINO_HOME}/bin/launcher run --etc-dir ${TRINO_CONF_DIR} --launcher-log-file ${TRINO_LAUNCHER_LOG} --server-log-file ${TRINO_SERVER_LOG}

