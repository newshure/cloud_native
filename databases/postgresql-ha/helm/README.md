# postgresql-ha Helm Chart

`databases/postgresql-ha/manifests/` 의 raw 매니페스트와 **동등한 결과**를 만드는 Helm Chart.

## 1. 설치

```bash
# 기본값으로 설치 (release name = chart name 으로 두면 raw 매니페스트와 동일한 리소스 이름 생성)
helm install postgresql-ha ./helm -n databases --create-namespace

# 커스텀 values 사용
helm install postgresql-ha ./helm -n databases -f my-values.yaml
```

## 2. 업그레이드

```bash
helm upgrade postgresql-ha ./helm -n databases -f my-values.yaml
helm rollback postgresql-ha <revision> -n databases   # 필요 시 롤백
```

## 3. 삭제

```bash
helm uninstall postgresql-ha -n databases
# PVC 는 Retain 정책 (chart 의 helm.sh/resource-policy: keep) 이라 별도 삭제
kubectl -n databases delete pvc \
  data-postgresql-ha-0 \
  data-postgresql-ha-1 \
  postgresql-ha-backup-volume
```

## 4. 자주 쓰는 values 예시

### 4.1. NodePort 충돌 회피 (다른 인스턴스와 동시 운용)

```yaml
# values-staging.yaml
service:
  read:
    nodePort: 31112
  write:
    nodePort: 31111
```

### 4.2. 외부 노출 비활성화 (ClusterIP 만)

```yaml
service:
  read:
    type: ClusterIP
  write:
    type: ClusterIP
```

### 4.3. StorageClass 변경

```yaml
persistence:
  data:
    storageClass: ceph-block-fast
    size: 128Gi
  backup:
    storageClass: ceph-fs-shared
    size: 200Gi
```

### 4.4. 외부에서 만든 backup PVC 재사용

```yaml
persistence:
  backup:
    enabled: true
    existingClaim: my-existing-rwx-pvc
```

### 4.5. anti-affinity 강제 (`required`) — Pod 가 반드시 다른 노드로

```yaml
podAntiAffinity:
  enabled: true
  type: required
  topologyKey: kubernetes.io/hostname
```

### 4.6. 노드 셀렉터 + Toleration

```yaml
nodeSelector:
  workload: database
tolerations:
  - key: dedicated
    operator: Equal
    value: db
    effect: NoSchedule
```

## 5. 검증

```bash
# 로컬 렌더링 결과 확인
helm template postgresql-ha ./helm -n databases | less

# 실제 클러스터에 적용했을 때 변경 사항 미리보기
helm install postgresql-ha ./helm -n databases --dry-run --debug
helm upgrade postgresql-ha ./helm -n databases --dry-run --debug

# Lint
helm lint ./helm
```

## 6. raw 매니페스트와의 매핑

| raw 매니페스트 | Helm Template |
|---|---|
| `manifests/01_rbac.yaml` (SA + Role + RB) | `templates/01_serviceaccount.yaml`, `01_role.yaml`, `01_rolebinding.yaml` |
| `manifests/02_lease.yaml` | `templates/02_lease.yaml` |
| `manifests/03_config.yaml` | `templates/03_configmap.yaml` |
| `manifests/04_services.yaml` | `templates/04_service-headless.yaml`, `04_service-read.yaml`, `04_service-write.yaml` |
| `manifests/05_pvc.yaml` | `templates/05_pvc-backup.yaml` |
| `manifests/06_statefulset.yaml` | `templates/06_statefulset.yaml` |
{.dense}

## 7. 기존 raw 매니페스트 배포본을 Helm 으로 인수 (adopt)

이미 `kubectl apply -f manifests/` 로 배포된 클러스터를 helm 관리로 이전할 때.

### 7.1. 사전 라벨링 (Helm 이 "내 것" 이라고 인지하도록)

```bash
NAMESPACE=databases
RELEASE=postgresql-ha

# Helm 이 인수하는 모든 리소스에 표준 메타데이터 부착
for r in \
  serviceaccount/postgresql-sa \
  role/postgresql-role \
  rolebinding/postgresql-rb \
  configmap/postgresql-config \
  pvc/postgresql-backup-volume \
  service/postgresql-ha-headless-service \
  service/postgresql-ha-read-service \
  service/postgresql-ha-write-service \
  statefulset/postgresql-ha \
  lease/postgres-primary-lease ; do
  kubectl -n "$NAMESPACE" annotate "$r" \
    meta.helm.sh/release-name="$RELEASE" \
    meta.helm.sh/release-namespace="$NAMESPACE" --overwrite
  kubectl -n "$NAMESPACE" label "$r" \
    app.kubernetes.io/managed-by=Helm --overwrite
done
```

### 7.2. helm install (기존 리소스 그대로 인수)

```bash
helm install "$RELEASE" ./helm -n "$NAMESPACE"
```

라벨/어노테이션 사전 부착 덕에 helm 은 "이미 내가 관리하는 리소스" 로 보고 그 자리에서 인수합니다.

### 7.3. 검증

```bash
helm list -n "$NAMESPACE"
helm get manifest "$RELEASE" -n "$NAMESPACE" | head -50
helm history "$RELEASE" -n "$NAMESPACE"
```

⚠️ 인수 후 첫 `helm upgrade` 가 라벨 등에서 정렬을 위해 약간의 메타데이터 변경 (예: chart label 추가) 을 가할 수 있습니다. spec 변경은 없습니다.

---

## 8. 주의사항

1. **release name = chart name (`postgresql-ha`)** 인 경우에만 raw 매니페스트와 정확히 동일한 리소스 이름이 생성됩니다. 다른 이름을 쓰면 STS/Service 등이 `<release>-postgresql-ha-*` 가 되며, env `POSTGRESQL_STS_NAME` / `POSTGRESQL_SYNC_NAMES` 도 함께 따라갑니다.
2. **`POSTGRESQL_SYNC_NAMES` 의 Pod 이름**이 STS 이름 + ordinal 과 일치해야 sync 모드가 동작합니다. 다른 release name 사용 시 [values.yaml](values.yaml) 의 `postgresql.syncNames` 도 함께 수정하세요.
3. **두 인스턴스 동시 운용 시 NodePort 30111/30112 충돌** — values 로 nodePort 를 분리해야 합니다.
4. **PVC retention** — Retain 정책 (`whenDeleted/whenScaled: Retain`) 입니다. 의도적 데이터 삭제 시에만 `kubectl delete pvc` 수동 실행.
5. **trust 인증** — 폐쇄망 전제. 외부 노출 시 `config.pgHba` 변경 + Secret 기반 패스워드 도입 필요.

## Sources

- Helm Chart Best Practices: https://helm.sh/docs/chart_best_practices/
- Helm Template Functions: https://helm.sh/docs/chart_template_guide/function_list/
- Helm — Take Ownership of Existing Resources: https://helm.sh/docs/howto/charts_tips_and_tricks/#tell-helm-not-to-uninstall-a-resource
- Kubernetes StatefulSet: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- 본 워크로드 운영 매뉴얼: [../README.md](../README.md)
