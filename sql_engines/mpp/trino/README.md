# trino

> Trino 479 분산 SQL 엔진 (Coordinator + Worker) — `databases` 네임스페이스 운영.
> 이미지: `harbor.nova.office/library/databases/trino`.

`cloud_native` 모노레포의 표준 컴포넌트 레이아웃을 따르며, raw 매니페스트와 Helm
chart 가 1:1 등가로 유지됩니다.

## 디렉터리 구성

```
sql_engines/mpp/trino/
├── README.md                  # (this file)
├── Dockerfile                 # Trino 479 이미지 빌드
├── files/
│   ├── built_at               # 빌드 타임스탬프
│   ├── bin/                   # 컨테이너 진입 스크립트 (init/coordinator/worker container.sh)
│   └── trino-server-{479,480}/  # 외부 다운로드 산출물 (.gitignore 처리)
├── manifests/                 # __NAMESPACE__ 토큰 raw 매니페스트
│   ├── 01_secret.yaml
│   ├── 02_configmap.yaml
│   ├── 03_services.yaml
│   ├── 04_pvc.yaml
│   ├── 05_coordinator.yaml
│   ├── 06_worker.yaml
│   ├── 07_ingress.yaml
│   └── 08_hpa.yaml
├── helm/                      # Helm chart (manifests 와 등가)
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── README.md
│   └── templates/
│       ├── _helpers.tpl
│       ├── NOTES.txt
│       └── 01_..08_*.yaml
└── scripts/
    └── deploy.sh              # render/apply/delete + __NAMESPACE__ 치환
```

## 핵심 설계

| 항목 | 결정 |
|---|---|
| coordinator 토폴로지 | Deployment, replicas=1, strategy=Recreate (PVC RWO) |
| worker 토폴로지 | StatefulSet, replicas=3, headless service via `trino-worker-service` |
| 인증 | TLS (cert Secret) + 파일 기반 password authenticator (bcrypt) |
| 인그레스 | NGINX, HTTPS termination, backend-protocol=HTTPS, host=`trino.ai.nova.office` |
| 오토스케일 | worker HPA, CPU/Memory 80% 평균 기준, min=2 / max=10 |
| 영속 스토리지 | `block-sc-delete` (RWO Block). spill 200Gi · heapdump 60Gi · data 10Gi (per worker) |
| 카탈로그 | postgresql 두 개 (trino DB / airflow DB) — placeholder 비밀번호, secrets-plugin 권장 |
| 종료 처리 | preStop 으로 Trino REST `SHUTTING_DOWN` 전이 후 grace sleep |
{.dense}

## 사용

### Raw 매니페스트 (envsubst 없이 placeholder 유지)

```bash
./scripts/deploy.sh render databases   # rendered/databases/ 출력만
./scripts/deploy.sh apply  databases   # __NAMESPACE__ 치환 후 apply
./scripts/deploy.sh delete databases   # 동일 매니페스트 기준 삭제
```

> **주의**: `01_secret.yaml` 과 `02_configmap.yaml` 의 카탈로그 본문은 `${...}`
> placeholder 입니다. apply 전에 envsubst, Sealed-Secrets, SOPS, ESO 중 하나로
> 실값을 주입하십시오. 본 스크립트는 placeholder 그대로 적용합니다 (의도된 안전장치).

### Helm

```bash
helm install trino ./helm -n databases --create-namespace
helm upgrade trino ./helm -n databases
helm uninstall trino -n databases
```

`helm install trino ./helm` 은 raw 매니페스트와 동일한 리소스 이름을 만듭니다
(release name = chart name 일 때).

## 이미지 빌드

```bash
# 1) 외부 산출물 준비
ls files/trino-server-479   # 또는 480

# 2) 빌드 + Harbor push (build.sh 가 있다면)
docker build -t harbor.nova.office/library/databases/trino:479-$(date +%Y%m%d) .
docker tag harbor.nova.office/library/databases/trino:479-$(date +%Y%m%d) \
            harbor.nova.office/library/databases/trino:latest
docker push harbor.nova.office/library/databases/trino:479-$(date +%Y%m%d)
docker push harbor.nova.office/library/databases/trino:latest
```

이미지 베이스: `harbor.nova.office/library/base/trino-base:latest` (별도 관리).

## 운영 메모

- **HPA vs spec.replicas**: HPA 가 부착되면 worker StatefulSet 의 `spec.replicas`
  는 HPA 가 동적으로 조정합니다. 초기 설치 시 `worker.replicas=3` 이지만
  HPA `minReplicas=2` 가 down-scale 할 수 있습니다 (정상 거동).
- **PVC 회수 정책**: `block-sc-delete` 는 reclaimPolicy=Delete. PVC 삭제 시
  PV 까지 삭제됩니다. 데이터 보존이 필요하면 별도 StorageClass 로 변경.
- **클로즈드 네트워크**: 폐쇄망 전제. Ingress 호스트는 사내 DNS 에 매핑되어야 함.
- **TLS 만료 갱신**: `trino-cert-secret` 의 `server.pem` 갱신 후 coordinator/worker
  롤링 재시작 (PEM 은 컨테이너 진입 시 keystore 변환).

## 트러블슈팅

| 증상 | 점검 |
|---|---|
| 워커가 클러스터에 합류하지 못함 | `discovery.uri` (worker env `TRINO_SERVER_DISCOVERY_URI`) 와 coordinator service 의 namespace FQDN 일치 여부 |
| 인증 실패 | `password.db` 의 bcrypt 해시, secret 마운트 경로 (`/opt/trino/etc/password.db`), authenticator 설정 |
| HPA 동작 안 함 | `metrics-server` 설치 / Pod resources.requests 값 존재 여부 |
| Ingress 502 | backend-protocol=HTTPS 어노테이션, 인증서 일치(`trino-cert-secret`) |
{.dense}

## Sources

- Trino 공식 문서: https://trino.io/docs/current/
- Trino HTTPS / 인증: https://trino.io/docs/current/security/tls.html
- Kubernetes StatefulSet: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- HorizontalPodAutoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- cloud_native 모노레포 컨벤션: [../../../README.md](../../../README.md)
