#!/bin/bash
# =============================================================================
# 배포 보조 스크립트
# - 목적: kubectl -n 옵션으로 배포할 때 RoleBinding 의 subject namespace 도 맞춰서 렌더링
# - 이유: RoleBinding.subjects[].namespace 는 kubectl -n 으로 자동 치환되지 않음
# =============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST_DIR="${BASE_DIR}/manifests"

usage() {
  cat <<EOU
usage:
  $0 render <namespace> [output_dir]
  $0 apply  <namespace>
  $0 delete <namespace>
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
ns="${2:-}"
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
