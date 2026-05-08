# trino — Helm chart

Trino 479 분산 SQL 엔진 (Coordinator + Worker) 을 Kubernetes 에 배포하는 Helm chart.
이미지 저장소 및 운영 컨벤션은 [`cloud_native`](../../../../) 모노레포 표준을 따릅니다.

## TL;DR

```bash
# 기본값으로 설치 (namespace = databases)
helm install trino ./helm -n databases --create-namespace

# 또는 raw 매니페스트와 동등한 결과를 raw 경로로 배포
../scripts/deploy.sh apply databases
```

> chart name(`trino`) 과 release name 을 동일하게 두면 raw 매니페스트와 리소스
> 이름(예: `trino-coordinator-service`, `trino-worker-configmap`) 이 100% 일치합니다.

## 사전 요건

- Kubernetes ≥ 1.30 (운영: hd-cluster, v1.35.x)
- StorageClass `block-sc-delete` (RWO Block) — coordinator/worker PVC 모두
- 사내 Harbor 접근 권한 (`harbor.nova.office/library/databases/trino`)
- NGINX Ingress Controller (chart 가 사용)
- `metrics-server` (HPA 활성 시 필수)

## 주요 values

| Key | Default | 설명 |
|---|---|---|
| `image.repository` | `harbor.nova.office/library/databases/trino` | 컨테이너 이미지 저장소 |
| `image.tag` | `latest` | 이미지 태그 |
| `coordinator.replicas` | `1` | coordinator Deployment replicas |
| `worker.replicas` | `3` | worker StatefulSet replicas (HPA 활성 시 minReplicas 가 우선) |
| `coordinator.resources` | requests cpu=2 mem=8Gi / limits cpu=4 mem=12Gi | coordinator 리소스 |
| `worker.resources` | requests cpu=8 mem=16Gi / limits cpu=10 mem=28Gi | worker 리소스 |
| `persistence.storageClass` | `block-sc-delete` | 모든 PVC 의 StorageClass |
| `persistence.worker.spill.size` | `200Gi` | worker spill 디스크 크기 |
| `service.coordinator.type` | `ClusterIP` | coordinator Service 유형 |
| `ingress.enabled` | `true` | Ingress 생성 여부 |
| `ingress.host` | `trino.ai.nova.office` | Ingress host |
| `ingress.backendPort` | `8443` | coordinator HTTPS 포트로 백엔드 연결 |
| `autoscaling.enabled` | `true` | worker HPA 활성 |
| `autoscaling.minReplicas` / `maxReplicas` | `2` / `10` | HPA 범위 |
| `catalogs.*` | postgresql_0, postgresql_0_airflow | catalog 이름 → `.properties` 본문 (placeholder 포함) |
{.dense}

자세한 항목은 [values.yaml](values.yaml) 참고.

## 구성 리소스

| 종류 | 이름 (release=trino, ns=databases 기준) |
|---|---|
| Secret | `trino-cert-secret`, `trino-password-db-secret` |
| ConfigMap | `trino-coordinator-configmap`, `trino-worker-configmap`, `trino-catalog-configmap` |
| Service | `trino-coordinator-service`, `trino-worker-service` |
| PVC | `trino-coordinator-data-volume`, `trino-coordinator-heapdump-volume` |
| Deployment | `trino-coordinator` |
| StatefulSet | `trino-worker` (volumeClaimTemplates: data/heapdump/spill) |
| Ingress | `trino` |
| HPA | `trino-scaler` |
{.dense}

## Secrets / Catalog placeholder 처리

본 chart 는 git 안전성을 위해 secret/catalog 본문에 `${...}` placeholder 를 그대로
유지합니다. 실 배포는 다음 중 하나를 권장합니다.

1. **Sealed-Secrets** — `kubeseal` 로 암호화한 SealedSecret 으로 교체
2. **External-Secrets-Operator + Vault** — 외부 secret store 동기화
3. **helm install --set-file** — OOB values 파일에서 envsubst 후 `--set-file`
4. **secrets-plugin** — Trino 카탈로그는 `${ENV:VAR}` 참조 가능 (이미지에 plugin 포함)

## 업그레이드 / 롤백

```bash
helm upgrade trino ./helm -n databases
helm rollback trino <REVISION> -n databases
```

PVC 는 chart uninstall 시 자동 삭제되지 않으므로 (`Retain`-like 효과), 필요 시
별도로 정리하십시오:

```bash
kubectl -n databases delete pvc -l app=trino-worker
kubectl -n databases delete pvc trino-coordinator-data-volume trino-coordinator-heapdump-volume
```

## raw 매니페스트와의 동등성

raw 매니페스트(`../manifests/`) 는 본 chart 의 default values 와 1:1 동등하게
유지됩니다. 변경 시 양쪽을 함께 갱신하거나, 한쪽을 source of truth 로 결정하여
다른 쪽은 폐기하십시오.

## Sources

- Trino 공식 문서: https://trino.io/docs/current/
- Helm Chart 작성 가이드: https://helm.sh/docs/chart_template_guide/
- cloud_native 모노레포 컨벤션: [../../../README.md](../../../README.md)
