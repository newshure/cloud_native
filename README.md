# cloud_native

사내 Kubernetes 클러스터(`hd-cluster`, k8s v1.35.x / Rocky Linux 9.7 / containerd 2.x / Calico / Rook-Ceph) 위에서 동작하는 **Cloud-Native 워크로드 모음 저장소**.

각 디렉터리는 하나의 운영 단위(StatefulSet/Deployment/Operator 등)를 담으며, 매니페스트·이미지 빌드 자산·운영 문서·운영 스크립트를 함께 둡니다.

---

## Repository Layout

```
cloud_native/
├── README.md                              # (this file)
├── databases/
│   └── postgresql-ha/                     # PostgreSQL 16 HA (Lease 기반 failover)
│       ├── Dockerfile, build.sh, README.md
│       ├── manifests/                     # numbered prefix + __NAMESPACE__ 토큰
│       ├── scripts/                       # entrypoint / role-manager / backup / probes / deploy
│       └── helm/                          # Helm chart (raw 매니페스트와 등가)
├── sql_engines/
│   └── mpp/
│       └── trino/                         # Trino 479 분산 SQL (coordinator + worker)
│           ├── Dockerfile, README.md
│           ├── files/                     # 진입 스크립트 + (gitignore) trino-server-*/
│           ├── manifests/                 # 8개 매니페스트 (numbered prefix, __NAMESPACE__ 토큰)
│           ├── scripts/deploy.sh          # render/apply/delete + 토큰 치환
│           └── helm/                      # Helm chart (raw 매니페스트와 등가)
├── sidecars/
│   └── healthz/                           # Python 3.13 / FastAPI K8s 사이드카
│       ├── Dockerfile, requirements.txt, README.md
│       ├── healthz/app/                   # FastAPI 앱 (checks / collectors / config / endpoints / utils)
│       ├── manifests/
│       │   ├── samples/                   # raw manifests + kustomization.yaml
│       │   └── helm/                      # Helm chart (NetworkPolicy 제외)
│       └── scripts/validate.py            # 매니페스트 검증기 (PyYAML)
└── development/
    └── vscode/                            # code-server 4.103.0 (Debian 13, multi-user)
        ├── Dockerfile, build.sh
        ├── manifests/                     # per-user(haedong/coxspace/stryu) ConfigMap/Secret/PVC/Deployment/Service
        ├── scripts/                       # deploy.sh / inspect.sh / undeploy.sh
        └── helm/                          # Helm chart
```

추가 워크로드는 동일한 카테고리(`databases/`, `sql_engines/`, `sidecars/`, `messaging/`, `observability/`, `ai/`, `llm-stack/`, `development/`, …) 아래에 추가합니다.

---

## Components

### databases/
| 컴포넌트 | 상태 | 설명 |
|---|---|---|
| [postgresql-ha](databases/postgresql-ha/) | 운영 검증 중 | PostgreSQL 16.13, Lease 기반 Active-Standby (replicas=2), pg_rewind→pg_basebackup 폴백, 주간 논리 백업. raw 매니페스트 + Helm chart 동등 제공 |
{.dense}

### sql_engines/
| 컴포넌트 | 상태 | 설명 |
|---|---|---|
| [mpp/trino](sql_engines/mpp/trino/) | 운영 중 (`databases` ns) | Trino 479 분산 SQL — coordinator(Deployment, replicas=1) + worker(StatefulSet, replicas=3, HPA min=2/max=10), TLS + 파일 기반 password authenticator, NGINX HTTPS Ingress, PostgreSQL 카탈로그 2종 |
{.dense}

### sidecars/
| 컴포넌트 | 상태 | 설명 |
|---|---|---|
| [healthz](sidecars/healthz/) | 신규 도입 (커밋 진행 중) | Python 3.13 / FastAPI Kubernetes 사이드카. `livenessProbe`/`readinessProbe` 엔드포인트 + 메인 컨테이너의 process / TCP / HTTP 관측, self·target·system 스냅샷 보고. Native sidecar 패턴(initContainer + `restartPolicy: Always`). raw 매니페스트(`samples/` kustomize) + Helm chart 모두 제공 |
{.dense}

### development/
| 컴포넌트 | 상태 | 설명 |
|---|---|---|
| [vscode](development/vscode/) | 신규 도입 (커밋 진행 중) | code-server 4.103.0 (Coder fork) 커스텀 이미지 — Debian 13 (trixie), Python 3.13 / Node.js 20 / Temurin JDK 21 / Docker CLI / kubectl 1.35 / Helm v3 / yq, Claude Code · OpenAI Codex CLI 사전 설치, ko_KR.UTF-8 / Asia/Seoul, 비루트 `coder`(UID 1000) + sudo. 사용자별(haedong/coxspace/stryu) ConfigMap·Secret·PVC·Deployment·Service 매니페스트 + Helm chart |
{.dense}

> `sidecars/healthz` 와 `development/vscode` 컴포넌트는 별도 커밋으로 dev 브랜치에 합류 예정 (이번 PR은 root README 만 갱신).

---

## 사전 환경 요건

- Kubernetes 클러스터: v1.30+ 권장 (운영 hd-cluster 는 v1.35.x)
- StorageClass (Rook-Ceph 기준):
  - **`block-sc-delete`** — RBD, default, reclaimPolicy=Delete (임시/캐시)
  - **`block-sc-retain`** — RBD, reclaimPolicy=Retain (영속 데이터, DB)
  - **`filesystem-sc`** — CephFS, RWX, reclaimPolicy=Retain (공유/백업)
  - 모두 `allowVolumeExpansion: true`
- IngressClass: **`nginx`** (k8s.io/ingress-nginx, NodePort 30080/30443) — 외부는 Nginx Proxy Manager 가 TLS 종료 + 호스트 라우팅
- 사내 컨테이너 레지스트리: **harbor.nova.office**
- `kubectl` v1.30+ 클라이언트, `helm` v3 (Helm chart 사용 시)
- 폐쇄망 또는 NetworkPolicy 통제 환경 (외부 노출 제한 필수)

---

## 공통 작업 흐름

각 컴포넌트 디렉터리에는 일반적으로 다음 파일이 포함됩니다.

1. `Dockerfile` / `build.sh` — 이미지 빌드 및 Harbor push
2. `manifests/` — namespace 토큰(`__NAMESPACE__`) 포함된 K8s 리소스 (numbered prefix `NN_<resource>.yaml`)
3. `scripts/deploy.sh` — `__NAMESPACE__` 렌더링 + `kubectl apply` 보조 (`render` / `apply` / `delete` 서브커맨드)
4. `helm/` — raw 매니페스트와 등가인 Helm chart (release name == chart name 시 리소스명 동일)
5. `README.md` — 컴포넌트별 운영 매뉴얼 (정상 상태 / 장애 대응 / 트러블슈팅)

### 배포 표준 패턴 (택1)

raw 매니페스트:
```bash
cd <category>/<component>            # 예: databases/postgresql-ha
./scripts/deploy.sh apply <namespace>
```

Helm chart:
```bash
cd <category>/<component>
helm install <release> ./helm -n <namespace> --create-namespace
helm upgrade <release> ./helm -n <namespace>
```

> 두 방식의 결과 리소스명은 동일하게 설계되어 있으므로 라이프사이클 도중 전환할 때 충돌이 발생하지 않습니다 (단, Helm 메타데이터 라벨 차이는 존재).

---

## 컨벤션

- **이미지 태그**: `harbor.nova.office/library/<project>/<name>:<version>-<YYYYMMDD>` + `:latest`
  - `<project>` 세그먼트는 운영 네임스페이스/Harbor project 와 정렬 (디렉터리 카테고리에서 자동 유도하지 않음). 예: `sql_engines/mpp/trino` 의 이미지는 운영 ns 일치하여 `library/databases/trino`
- **네임스페이스**: 컴포넌트별 분리(`databases`, `message-queue`, `monitoring`, `airflow`, `llm-stack`, …)
- **라벨**: `app=<component-name>`, 역할 분리는 `role=<value>` 사용 (예: `role=master`)
- **포트**: NodePort 30000 번대 사용, 컴포넌트 간 충돌 회피 (운영 예: `30080/30443` ingress-nginx, `30111/30112` postgresql-ha)
- **파일 인코딩**: UTF-8 (BOM 없이)
- **줄 끝**: LF (.gitattributes 강제, Windows 체크아웃에서도 CRLF 금지)
- **시크릿**: `*.key`, `*.pem`, `*.p12`, `*.pfx`, `.env`, `secrets/`, `kubeconfig` — `.gitignore` 차단. 매니페스트의 비밀값은 `${PLACEHOLDER}` 로 두고 Sealed-Secrets / SOPS / External-Secrets-Operator / envsubst 중 하나로 주입

---

## 라이선스 / 책임

사내 운영 자산. 외부 공개 금지.

---

## Sources

- 컴포넌트 README: [databases/postgresql-ha/README.md](databases/postgresql-ha/README.md), [sql_engines/mpp/trino/README.md](sql_engines/mpp/trino/README.md)
- Helm chart 가이드: [databases/postgresql-ha/helm/README.md](databases/postgresql-ha/helm/README.md), [sql_engines/mpp/trino/helm/README.md](sql_engines/mpp/trino/helm/README.md)
- 외부 참조:
  - Kubernetes v1.35 docs: <https://kubernetes.io/docs/home/>
  - Rook-Ceph: <https://rook.io/docs/rook/latest/Getting-Started/intro/>
  - ingress-nginx: <https://kubernetes.github.io/ingress-nginx/>
  - Trino docs: <https://trino.io/docs/current/>
  - PostgreSQL 16: <https://www.postgresql.org/docs/16/>
  - Helm chart template guide: <https://helm.sh/docs/chart_template_guide/>
