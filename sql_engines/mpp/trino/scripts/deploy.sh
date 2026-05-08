#!/bin/bash
# =============================================================================
# Trino 배포 보조 스크립트
# - 목적: __NAMESPACE__ 토큰을 실제 namespace 로 치환 후 kubectl apply
# - 이유: secret/configmap/PVC/workload 가 모두 namespace 종속이며
#         placeholder secret/cm 는 별도 envsubst 단계 후 배포해야 함.
# =============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_DIR="${BASE_DIR}/manifests"
DEFAULT_NAMESPACE="databases"

usage() {
  cat <<EOU
usage:
  $0 render <namespace> [output_dir]
  $0 apply  <namespace>
  $0 delete <namespace>

namespace 기본값: ${DEFAULT_NAMESPACE}

주의:
  01_secret.yaml / 02_configmap.yaml (catalog) 은 \${...} placeholder 를 포함합니다.
  실 배포 전 envsubst 또는 Sealed-Secrets/SOPS/External-Secrets-Operator 로
  실값 주입 후 apply 하십시오. 이 스크립트는 placeholder 그대로 apply 합니다.
EOU
}

render() {
  local namespace="$1"
  local out_dir="${2:-${BASE_DIR}/rendered/${namespace}}"
  mkdir -p "$out_dir"

  for file in "${MANIFEST_DIR}"/*.yaml; do
    sed "s/__NAMESPACE__/${namespace}/g" "$file" > "${out_dir}/$(basename "$file")"
  done

  echo "$out_dir"
}

apply_manifests() {
  local namespace="$1"
  local out_dir
  out_dir=$(render "$namespace")
  kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"
  kubectl apply -n "$namespace" -f "$out_dir"
}

delete_manifests() {
  local namespace="$1"
  local out_dir
  out_dir=$(render "$namespace")
  kubectl delete -n "$namespace" -f "$out_dir" --ignore-not-found
}

cmd="${1:-}"
ns="${2:-${DEFAULT_NAMESPACE}}"
case "$cmd" in
  render)
    [[ -n "$ns" ]] || { usage; exit 2; }
    render "$ns" "${3:-}"
    ;;
  apply)
    [[ -n "$ns" ]] || { usage; exit 2; }
    apply_manifests "$ns"
    ;;
  delete)
    [[ -n "$ns" ]] || { usage; exit 2; }
    delete_manifests "$ns"
    ;;
  *)
    usage
    exit 2
    ;;
esac
