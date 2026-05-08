# cloud_native

사내 Kubernetes 클러스터(`hd-cluster`, k8s v1.35.x / Rocky Linux 9.7 / containerd 2.x / Calico / Rook-Ceph) 위에서 동작하는 **Cloud-Native 워크로드 모음 저장소**.

각 디렉터리는 하나의 운영 단위(StatefulSet/Deployment/Operator 등)를 담으며, 매니페스트·이미지 빌드 자산·운영 문서·운영 스크립트를 함께 둡니다.

---

## Repository Layout

```
cloud_native/
├── README.md                       # (this file)
└── databases/
    └── postgresql-ha/              # PostgreSQL 16 HA (Lease 기반 failover, RWO data + RWX backup)
        ├── Dockerfile              # HA 운영 스크립트가 추가된 PostgreSQL 16.13 이미지
        ├── build.sh                # Harbor push 빌드 스크립트
        ├── OPERATIONS.md           # 운영 매뉴얼 (12 챕터)
        ├── manifests/              # K8s 리소스 (RBAC, Lease, ConfigMap, Service, PVC, StatefulSet)
        └── scripts/                # 컨테이너 내부 스크립트 (entrypoint / role-manager / backup / etc.)
```

추가 워크로드는 동일한 카테고리(`databases/`, `messaging/`, `observability/`, `ai/`, …) 아래에 추가합니다.

---

## Components

### databases/
| 컴포넌트 | 상태 | 설명 |
|---|---|---|
| [postgresql-ha](databases/postgresql-ha/) | 운영 검증 중 | PostgreSQL 16.13, Lease 기반 Active-Standby (replicas=2), pg_rewind→pg_basebackup 폴백, 주간 논리 백업 |
{.dense}

---

## 사전 환경 요건

- Kubernetes 클러스터: v1.30+ 권장
- StorageClass:
  - 데이터용 RWO Block (Retain) — 예: Rook-Ceph RBD
  - 백업/공유용 RWX Filesystem — 예: Rook-Ceph CephFS
- 사내 컨테이너 레지스트리 (Harbor) 접근 권한
- `kubectl` v1.30+ 클라이언트
- 폐쇄망 또는 NetworkPolicy 통제 환경 (워크로드별 인증 정책에 따라 외부 노출 제한 필수)

---

## 공통 작업 흐름

각 컴포넌트 디렉터리에는 일반적으로 다음 파일이 포함됩니다.

1. `Dockerfile` / `build.sh` — 이미지 빌드 및 Harbor push
2. `manifests/` — namespace 토큰(`__NAMESPACE__`) 포함된 K8s 리소스
3. `scripts/deploy.sh` — namespace 렌더링 + `kubectl apply` 보조
4. `OPERATIONS.md` — 정상 상태 / 장애 대응 / 백업 절차

배포 표준 패턴:

```bash
cd databases/postgresql-ha
./scripts/deploy.sh apply <target-namespace>
```

---

## 컨벤션

- **이미지 태그**: `harbor.nova.office/library/<category>/<name>:<version>-<YYYYMMDD>` + `:latest`
- **네임스페이스**: 컴포넌트별 분리(`databases`, `message-queue`, `monitoring`, `airflow`, `llm-stack`, …)
- **라벨**: `app=<component-name>`, 역할 분리는 `role=<value>` 사용 (예: `role=master`)
- **포트**: NodePort 30000 번대 사용, 컴포넌트 간 충돌 회피
- **파일 인코딩**: UTF-8 (BOM 없이)
- **줄 끝**: LF (셸 스크립트 호환)

---

## 라이선스 / 책임

사내 운영 자산. 외부 공개 금지.
