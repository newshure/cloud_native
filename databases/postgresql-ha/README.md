# postgresql-ha

Kubernetes 위에서 동작하는 **PostgreSQL 16 HA 스택**.
- **Lease 기반 Active–Standby** failover (외부 클러스터 매니저 없이 자체 컨트롤)
- **Read 가용성 우선** 정책 (장애 중에도 read endpoint 최대한 유지)
- **자동 복구 우선** (`pg_rewind` → `pg_basebackup` 폴백, 그래도 안 되면 운영자가 `restore-all.sh`)
- **한국어 환경** 기본 (`UTF-8` / `ko_KR.UTF-8` 명시 적용, `Asia/Seoul`)

---

## 1. 개요

| 항목 | 값 |
|---|---|
| PostgreSQL 버전 | 16.13 (단일 메이저 고정) |
| 베이스 이미지 | `harbor.nova.office/library/databases/postgresql-16:latest` |
| 토폴로지 | StatefulSet replicas=2 (`postgresql-ha-0` / `postgresql-ha-1`) |
| HA 컨트롤러 | Kubernetes `Lease` (`coordination.k8s.io/v1`) + sidecar `role-manager` |
| 복제 방식 | Streaming Replication (slot 기반), sync/async 동적 전환 |
| 인증 | `trust` (폐쇄망 전제, 네트워크 레벨 통제 필수) |
| 백업 | 논리 백업 (`pg_dumpall --globals-only` + `pg_dump -Fc`), 매주 1회, 56일 보관 |
| 인코딩 / 로케일 | `UTF-8` / `ko_KR.UTF-8` (initdb·conf·env 모두 명시) |
{.dense}

---

## 2. 아키텍처

### 2.1. 컴포넌트 구성

```
         ┌────────────────────────── databases ns ───────────────────────────┐
         │                                                                    │
         │   ┌─ Service: postgresql-ha-write-service (NodePort 30111) ───┐   │
         │   │   selector: app=postgresql-ha, role=master                │   │
         │   └──────────────────────┬─────────────────────────────────────┘   │
         │                          │                                         │
         │   ┌─ Service: postgresql-ha-read-service (NodePort 30112) ────┐   │
         │   │   selector: app=postgresql-ha                              │   │
         │   └──────────────────────┬───────────────┬────────────────────┘   │
         │                          │               │                         │
         │   ┌── Pod postgresql-ha-0 ─┐   ┌── Pod postgresql-ha-1 ─┐         │
         │   │ container: postgresql  │   │ container: postgresql   │         │
         │   │ container: role-manager│   │ container: role-manager │         │
         │   │ container: backup-cron │   │ container: backup-cron  │         │
         │   │ initC: init-check-dir  │   │ initC: init-check-dir   │         │
         │   │ initC: init-ha-bootstrap│  │ initC: init-ha-bootstrap│         │
         │   │ PVC data (RWO 64Gi)    │   │ PVC data (RWO 64Gi)     │         │
         │   └────────────┬───────────┘   └────────────┬────────────┘         │
         │                │ streaming replication      │                       │
         │                ├─────────── slot ───────────┤                       │
         │                │                            │                       │
         │   ┌─ PVC postgresql-backup-volume (RWX 50Gi, CephFS) ─┐            │
         │   │   mounted on backup-cron of both pods            │            │
         │   └────────────────────────────────────────────────────┘            │
         │                                                                    │
         │   Lease: postgres-primary-lease (30s TTL)  ←── role-manager renews  │
         │                                                                    │
         └────────────────────────────────────────────────────────────────────┘
```

### 2.2. Pod 내부 컨테이너 책임

| 컨테이너 | 역할 |
|---|---|
| `init-check-dir` (initContainer) | UID 0 으로 PVC 권한·디렉터리 설정 |
| `init-ha-bootstrap` (initContainer) | Primary/Replica 분기 결정 + initdb / pg_basebackup / pg_rewind 수행 |
| `postgresql` (main) | `postgres` 프로세스 실행 (PID 1 아님 — `shareProcessNamespace: true`) |
| `role-manager` (sidecar) | Lease 갱신, role 라벨 관리, sync↔async 전환, self-fence |
| `backup-cron` (sidecar) | 정기 백업 (DOW=6, 02:00) + 시작 시 catch-up |
{.dense}

### 2.3. HA 동작 모드 (init-ha-bootstrap.sh 분기)

| Mode | 조건 | 동작 |
|---|---|---|
| **A** | PGDATA 없음 + Lease 획득 성공 | initdb → 첫 Primary 가 됨 |
| **B** | PGDATA 없음 + Lease 획득 실패 | peer Primary 대기 → `pg_basebackup` → Replica 합류 |
| **C** | PGDATA 있음 + 본인이 Lease holder | Primary 로 그대로 재기동 |
| **D** | PGDATA 있음 + 다른 Pod 가 holder | `pg_rewind` 시도 → 실패 시 fresh `pg_basebackup` |
| **E-Primary** | PGDATA 있음 + Lease 비어 있음 + 경합 승리 | Primary 재기동 |
| **E-Replica** | PGDATA 있음 + Lease 비어 있음 + 경합 패배 | Replica 로 재합류 |
{.dense}

### 2.4. 운영 원칙

1. **Read 유지 우선** — readiness 는 streaming 상태를 보지 않음 → stale read 가능성 감수
2. **자동 복구 우선** — `pg_rewind` → `pg_basebackup` → 운영자 수동 복구 순
3. **수동 복구는 최후 수단** — `restore-all.sh` 로 globals + DB dump 전체 복원
4. **write 안전성은 Lease + role-manager 로 통제** — write-service 셀렉터 `role=master` 라벨 1개에만 매칭

---

## 3. 사전 요구사항

### 3.1. 클러스터

| 항목 | 요구 |
|---|---|
| Kubernetes | v1.30+ (현재 검증 환경 v1.35.3) |
| 컨테이너 런타임 | containerd 2.x 권장 |
| CNI | NetworkPolicy 지원 권장 (Calico 등) |
| 노드 OS | Linux x86_64 (RHEL 계열 검증, glibc 기반) |
| 노드 수 | 2 이상 (podAntiAffinity 분산용) |
{.dense}

### 3.2. StorageClass

| 용도 | accessMode | reclaim | 권장 프로비저너 | 매니페스트 기본값 |
|---|---|---|---|---|
| data (Pod 별) | RWO | Retain | RBD (블록) | `block-sc-retain` |
| backup (공유) | RWX | Retain | CephFS / NFS | `filesystem-sc` |
{.dense}

⚠️ backup 은 두 Pod 가 동시 mount 가능해야 하므로 **반드시 RWX**.

### 3.3. 컨테이너 레지스트리

- 사설 레지스트리 (예: `harbor.nova.office`) 접근 권한
- StatefulSet 의 `imagePullPolicy: Always` 유지

### 3.4. 네트워크 / 보안

현재 예제는 `trust` 인증입니다. 따라서 **다음 조건이 필수**입니다.

1. 외부 직접 노출 금지 (NodePort 30111/30112 에 클러스터 외부 인바운드 차단)
2. NetworkPolicy 또는 사설망 통제
3. write-service 는 기본 ClusterIP 권장 (NodePort 가 꼭 필요한 경우만 노출)

---

## 4. 저장소 구조

```
databases/postgresql-ha/
├── README.md                    # (this file)
├── Dockerfile                   # PG 16.13 베이스에 HA 스크립트 + glibc-langpack-ko 추가
├── build.sh                     # Harbor build/push 스크립트
├── manifests/                   # K8s 리소스 (namespace 토큰 __NAMESPACE__ 포함)
│   ├── 01_rbac.yaml             # ServiceAccount + Role + RoleBinding
│   ├── 02_lease.yaml            # 빈 Lease 사전 생성 (없어도 자동 생성됨)
│   ├── 03_config.yaml           # postgresql.conf / pg_hba.conf / pg_ident.conf
│   ├── 04_services.yaml         # headless / read NodePort / write NodePort
│   ├── 05_pvc.yaml              # backup PVC (RWX 50Gi)
│   └── 06_statefulset.yaml      # StatefulSet (data PVC RWO 64Gi via VCT)
├── helm/                        # Helm Chart (manifests 와 동등한 배포 옵션)
└── scripts/                     # 컨테이너 안에서 실행되는 셸 스크립트 (이미지에 COPY)
    ├── common.sh                # 공통 함수 (pg_set_env / k8s_get/put/post/patch / lease 헬퍼)
    ├── entrypoint.sh            # postgres 메인 컨테이너 진입점
    ├── init-ha-bootstrap.sh     # 부팅 시 Primary/Replica 분기 (Mode A~E)
    ├── role-manager.sh          # Lease 갱신, role 라벨, sync 모드 토글, self-fence
    ├── readiness.sh             # Read 가용성 우선 readiness probe
    ├── liveness.sh              # 최소 liveness probe
    ├── prestop.sh               # 종료 직전 sync→async 완화 후 fast stop
    ├── backup.sh                # 정기/catch-up 백업 (globals + DB dump + manifest)
    ├── backup-cron.sh           # 1분 단위 스케줄 평가 데몬 (cron 미사용)
    ├── restore-all.sh           # 최종 수동 복구용 전체 복원
    └── deploy.sh                # namespace 렌더링 (__NAMESPACE__ 치환) + apply
```

---

## 5. 빌드

```bash
cd databases/postgresql-ha
./build.sh
```

`build.sh` 동작:

1. `harbor.nova.office/library/databases/postgresql:16.13-YYYYMMDD` 태그로 빌드
2. 동일 이미지를 `:latest` 로 추가 태깅 후 push
3. StatefulSet 의 `image: ...:latest` + `imagePullPolicy: Always` 가 새 이미지를 가져감

⚠️ `:latest` push 후에도 즉시 반영되지는 않습니다. 다음 중 하나가 필요합니다.

```bash
# 롤링 재시작
kubectl -n databases rollout restart sts/postgresql-ha
kubectl -n databases rollout status sts/postgresql-ha
```

---

## 6. 배포

두 가지 배포 방식을 모두 지원합니다.

### 6.1. (방식 A) raw manifests + deploy.sh

```bash
# namespace 렌더링 후 apply (__NAMESPACE__ 치환 포함)
./scripts/deploy.sh apply databases

# 또는 분리:
./scripts/deploy.sh render databases /tmp/postgresql-ha-rendered
kubectl apply -n databases -f /tmp/postgresql-ha-rendered
```

### 6.2. (방식 B) Helm Chart

```bash
# 설치
helm install postgresql-ha ./helm -n databases --create-namespace

# 업그레이드
helm upgrade postgresql-ha ./helm -n databases -f my-values.yaml

# 제거 (PVC 는 Retain 정책이라 보존됨)
helm uninstall postgresql-ha -n databases
```

자세한 values 옵션은 [helm/values.yaml](helm/values.yaml) 참고.

### 6.3. 배포 후 확인

```bash
kubectl -n databases get pods -o wide
kubectl -n databases get svc
kubectl -n databases get lease postgres-primary-lease -o yaml
kubectl -n databases get pods -L role
```

확인 포인트:

1. Pod 2개가 모두 Running, READY 3/3
2. 한 Pod 만 `role=master` 라벨 보유
3. read-service endpoint 는 두 Pod 모두 포함
4. write-service endpoint 는 master 1개만 포함

### 6.4. namespace 변경 시 (방식 A 전용)

`RoleBinding.subjects[].namespace` 는 `kubectl -n` 만으로는 치환되지 않습니다. **반드시 `deploy.sh` 사용** (방식 B 인 Helm 은 자동 처리).

---

## 7. 설정 레퍼런스

### 7.1. StatefulSet 환경변수

`init-ha-bootstrap` / `postgresql` / `role-manager` / `backup-cron` 모두 동일 env 셋을 받습니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `POSTGRESQL_VERSION` | `16` | 메이저 버전 |
| `POSTGRESQL_DATA_DIR` | `/opt/postgresql/data` | PGDATA |
| `POSTGRESQL_BACKUP_DIR` | `/opt/postgresql/backup` | 공유 백업 루트 |
| `POSTGRESQL_ENCODING` | `UTF-8` | initdb encoding |
| `POSTGRESQL_LOCALE` | `ko_KR.UTF-8` | initdb locale |
| `POSTGRESQL_PORT` | `5432` | 리스닝 포트 |
| `POSTGRESQL_SUPERUSER` | `postgres` | superuser 이름 |
| `POSTGRESQL_REPLICATION_USER` | `postgres` | 복제 user (trust 인증 전제) |
| `POSTGRESQL_REPLICAS` | `2` | replica count (현 구성 고정) |
| `POSTGRESQL_STS_NAME` | `postgresql-ha` | StatefulSet 이름 (peer host 계산에 사용) |
| `POSTGRESQL_HEADLESS_SVC_NAME` | `postgresql-ha-headless-service` | DNS suffix 계산용 |
| `POSTGRESQL_LEASE_NAME` | `postgres-primary-lease` | Lease 리소스명 |
| `POSTGRESQL_LEASE_DURATION_SEC` | `30` | Lease TTL |
| `POSTGRESQL_MASTER_LABEL_VALUE` | `master` | role 라벨 값 |
| `POSTGRESQL_SYNC_NAMES` | `ANY 1 (postgresql-ha-0,postgresql-ha-1)` | synchronous_standby_names |
| `POSTGRESQL_ROLE_MGR_LOOP_SEC` | `5` | role-manager 루프 주기 |
| `POSTGRESQL_PEER_FAIL_THRESHOLD` | `3` | peer 실패 누적 임계 (takeover 트리거) |
| `POSTGRESQL_ISOLATION_THRESHOLD` | `3` | API+peer 동시 실패 임계 (self-fence) |
| `POSTGRESQL_RENEW_FAIL_THRESHOLD` | `3` | Lease 갱신 실패 임계 (demote) |
| `POSTGRESQL_PEER_WAIT_SEC` | `600` | peer Primary 준비 최대 대기 |
| `POSTGRESQL_BACKUP_RETENTION_DAYS` | `56` | 백업 보관 일수 (8주) |
| `POSTGRESQL_BACKUP_SCHEDULE_DOW` | `6` | 정기 백업 요일 (1=월 … 7=일, 6=토) |
| `POSTGRESQL_BACKUP_SCHEDULE_HOUR` | `2` | 정기 백업 시각 |
| `POSTGRESQL_BACKUP_COMPRESSION_LEVEL` | `6` | pg_dump -Z 레벨 |
{.dense}

### 7.2. ConfigMap `postgresql-config`

`postgresql.conf` 핵심 항목:

| 항목 | 값 | 비고 |
|---|---|---|
| `wal_level` | `replica` | 스트리밍 복제 |
| `max_wal_senders` | `10` | |
| `max_replication_slots` | `10` | |
| `hot_standby` | `on` | Replica read 허용 |
| `wal_log_hints` | `on` | pg_rewind 전제 |
| `wal_keep_size` | `1GB` | slot 보조 |
| `max_slot_wal_keep_size` | `4GB` | slot 폭주 가드 |
| `hot_standby_feedback` | `on` | replica conflict 완화 |
| `synchronous_commit` | `on` | sync 일 때만 의미 |
| `synchronous_standby_names` | `''` (런타임에 role-manager 가 설정) | sync↔async 동적 전환 |
| `archive_mode` | `off` | (PITR 미사용) |
| `timezone` / `log_timezone` | `Asia/Seoul` | |
| `lc_messages/monetary/numeric/time` | `ko_KR.UTF-8` | |
| `default_text_search_config` | `pg_catalog.simple` | |
{.dense}

`pg_hba.conf`: 폐쇄망 전제로 `0.0.0.0/0` 와 `::/0` 에 `trust`. 외부 노출 시 즉시 변경 필요.

### 7.3. RBAC 권한

`postgresql-sa` ServiceAccount 가 받는 권한:

| 리소스 | verbs | 용도 |
|---|---|---|
| `coordination.k8s.io/leases` | get, list, watch, create, update, patch | Lease 획득/갱신 |
| `pods` | get, list, watch, patch | 자기 자신에 `role` 라벨 patch |
| `services`, `endpoints` | get, list, watch | 디버깅·관찰용 |
{.dense}

`init-ha-bootstrap` 은 in-cluster ServiceAccount 토큰을 사용해 Lease 를 직접 호출합니다.

---

## 8. 인코딩 / 로케일

본 워크로드는 **한국어 환경** 을 전제하며 다음 규칙을 따릅니다:

- **모든 위치에서 명시적으로 `UTF-8` / `ko_KR.UTF-8` 을 박는다** (전역 설정에 의존하지 않는다).

| 위치 | 적용 |
|---|---|
| Dockerfile | `glibc-langpack-ko` 설치, `TZ=Asia/Seoul`, `/etc/localtime` symlink |
| StatefulSet env | `POSTGRESQL_ENCODING=UTF-8`, `POSTGRESQL_LOCALE=ko_KR.UTF-8` |
| `postgresql.conf` | `lc_messages/lc_monetary/lc_numeric/lc_time = 'ko_KR.UTF-8'` |
| `init-ha-bootstrap.sh` initdb | `--encoding="${POSTGRESQL_ENCODING}"`, `--locale="${POSTGRESQL_LOCALE}"` |
{.dense}

⚠️ **권장 보강 (현재 누락 — 필요 시 후속 패치)**:

- Dockerfile 에 `ENV LANG=ko_KR.UTF-8 LC_ALL=ko_KR.UTF-8` 추가
- `postgresql.conf` 에 `client_encoding = 'UTF8'` 명시
- initdb 에 `--lc-collate=ko_KR.UTF-8 --lc-ctype=ko_KR.UTF-8` 분리 명시
- backup/restore 스크립트에 `PGCLIENTENCODING=UTF8` env 주입

---

## 9. 운영

### 9.1. 정상 상태 점검

```bash
# Primary 확인
kubectl -n databases get pods -l role=master

# 내부 확인
PRIMARY=$(kubectl -n databases get pods -l role=master -o jsonpath='{.items[0].metadata.name}')
kubectl -n databases exec -it "$PRIMARY" -c postgresql -- \
  psql -U postgres -At -c "SELECT pg_is_in_recovery();"     # f 면 Primary

# 복제 상태
kubectl -n databases exec -it "$PRIMARY" -c postgresql -- \
  psql -U postgres -d postgres -x -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"

# Lease 상태
kubectl -n databases get lease postgres-primary-lease -o yaml | grep -E 'holder|renewTime'
```

### 9.2. 롤링 재시작

```bash
kubectl -n databases rollout restart sts/postgresql-ha
kubectl -n databases rollout status sts/postgresql-ha
```

확인 포인트: `podManagementPolicy: OrderedReady` 라 한 번에 1 Pod 씩만 내려가며 read endpoint 가 비지 않음.

### 9.3. 장애 대응 우선순위

1. **Lease 기반 자동 failover** — role-manager 가 자동 처리
2. **Primary 재시작 시 `pg_rewind`** — init-ha-bootstrap 의 Mode D
3. **`pg_rewind` 실패 시 `pg_basebackup`** — 동일 Mode 안에서 폴백
4. **그래도 안 되면 운영자가 reset 후 `restore-all.sh`** — Section 9.6

### 9.4. Read 우선 정책의 함의

readiness 가 streaming 상태를 검사하지 않습니다. 따라서 의도된 동작:

1. Replica 가 stale 이어도 read endpoint 에 남을 수 있음
2. write 안전성은 Lease + role 라벨 + write-service selector 로 통제
3. 강한 read-after-write 일관성이 필요한 서비스라면 별도 라우팅 전략 필요

### 9.5. 백업 확인

```bash
kubectl -n databases exec -it postgresql-ha-0 -c backup-cron -- \
  ls -al /opt/postgresql/backup/postgresql-ha-0/scheduled
kubectl -n databases exec -it postgresql-ha-1 -c backup-cron -- \
  ls -al /opt/postgresql/backup/postgresql-ha-1/scheduled
```

산출물:
- `*_globals_<timestamp>.sql` — pg_dumpall --globals-only
- `*_manifest_<timestamp>.txt` — DB 목록 (한 줄 1개)
- `*_<dbname>_<timestamp>.dump` — DB 별 custom format dump

### 9.6. 자동 복구 실패 시 수동 복구

#### 부분 복구 (특정 Replica 만)

1. 대상 Pod 의 data PVC 정리
2. Pod 재기동 시 `init-ha-bootstrap.sh` 가 fresh `pg_basebackup` 자동 수행

#### 전체 복구 (자동 self-fix 실패 시 최종 수단)

```bash
# Step 1. 서비스 영향 통제 (write 차단)
# Step 2. 한 Pod 를 clean 상태로 확보 (필요 시 PVC reset)
# Step 3. 백업 세트 선택 (timestamp 일치하는 globals + manifest + dump 들)
# Step 4. 전체 복원
/opt/postgresql/bin/restore-all.sh /opt/postgresql/backup/postgresql-ha-0
# 또는
/opt/postgresql/bin/restore-all.sh /opt/postgresql/backup/postgresql-ha-0/scheduled
# Step 5. 다른 Pod 초기화 후 재기동 (Replica 자동 합류)
```

---

## 10. 운영자가 자주 보는 로그

```bash
kubectl -n databases logs postgresql-ha-0 -c postgresql
kubectl -n databases logs postgresql-ha-0 -c role-manager
kubectl -n databases logs postgresql-ha-0 -c backup-cron
kubectl -n databases logs postgresql-ha-1 -c postgresql
kubectl -n databases logs postgresql-ha-1 -c role-manager
kubectl -n databases logs postgresql-ha-1 -c backup-cron
```

중점 검색 키워드:

| 키워드 | 의미 |
|---|---|
| `Mode A` / `B` / `C` / `D` / `E-Primary` / `E-Replica` | init-ha-bootstrap 분기 결과 |
| `Lease acquired` / `Lease 갱신 실패` | Lease 라이프사이클 |
| `Demote` | Lease/peer 문제로 자기 강등 |
| `SELF-FENCE` | API + peer 동시 차단 시 자기 정지 |
| `pg_rewind` | rejoin 시도 |
| `pg_basebackup` | fresh basebackup 폴백 |
| `백업 완료` / `백업 시작` | backup-cron 활동 |
{.dense}

---

## 11. 트러블슈팅

| 증상 | 확인 | 조치 |
|---|---|---|
| 두 Pod 모두 Pending | `kubectl describe pod`, StorageClass 존재 여부 | SC 이름 매칭, RWX 지원 확인 |
| Pod READY 2/3 | `role-manager` 로그의 `Lease 권한 오류` | RBAC 적용 누락 — `deploy.sh apply` 재실행 |
| `pg_is_in_recovery()=t` 둘 다 | Lease holder 비어있고 takeover 실패 | role-manager 로그에서 takeover 시도 결과 확인 |
| `role=master` 라벨 안 붙음 | `pods/patch` 권한 부재 | Role 의 pods verbs 에 `patch` 포함 확인 |
| write-service endpoint 비어있음 | master 라벨 미부착 또는 Pod NotReady | 위 두 항목 확인 |
| read-service endpoint 한쪽만 | 한 Pod NotReady | Pod 로그 확인, 필요 시 PVC reset 후 재기동 |
| `pg_basebackup: ERROR: replication slot ... is in use` | 이전 슬롯 잔존 | Primary 에서 `pg_drop_replication_slot('<name>')` |
| pg_rewind 실패 후 fresh basebackup 도 실패 | peer Primary 미준비 | peer 가동 확인, `POSTGRESQL_PEER_WAIT_SEC` 증가 |
| sync_state 가 계속 `async` | peer streaming 끊김 또는 임계치 누적 | role-manager 로그의 peer_fail 카운터 확인 |
| 백업 미생성 | `backup-cron` 컨테이너 로그 | DOW/HOUR env 확인, RWX PVC mount 확인 |
| 한글 메시지 ?? 깨짐 | locale 미설치 또는 client_encoding 차이 | 컨테이너 안 `locale -a \| grep ko_KR` |
{.dense}

---

## 12. 알려진 이슈 / 제한사항

1. **PG 16 의 `pg_replication_slots.invalidation_reason` 컬럼 부재**
   - `init-ha-bootstrap.sh` 의 `rejoin_as_replica()` 가 PG 17+ 의 컬럼을 참조 → 쿼리 실패
   - 안전망 (`2>/dev/null || echo "missing"`) 덕에 결과적으로 fresh basebackup 으로 폴백 → 의도된 결과로 동작
   - 향후 PG 16 호환 컬럼 (`wal_status='lost'` / `conflicting=true`) 으로 수정 예정
2. **슬롯 이름 하드코딩**
   - `init_primary()` 가 `postgresql_0_slot` / `postgresql_1_slot` 을 하드코딩
   - 실제 사용 슬롯은 `POD_NAME` 기반 (`postgresql_ha_0_slot` / `postgresql_ha_1_slot`)
   - 결과: 더미 슬롯 2개가 항상 생성됨 (무해, 미사용)
3. **trust 인증**
   - 운영 단순화를 위함 — 네트워크 레벨 통제 필수
   - 향후 SCRAM-SHA-256 + Secret 기반 비밀번호로 강화 예정
4. **WAL Archive 미사용 → PITR 불가**
   - 현재 백업은 매주 1회 논리 백업 → RPO 최대 1주
   - 짧은 RPO 가 필요하면 WAL archive (`archive_mode=on`) + S3/CephFS 적재 추가 검토
5. **replicas=2 고정 가정**
   - 스크립트의 peer 계산 (`(ORD+1) % 2`), `synchronous_standby_names` 등이 2 노드 전제
   - 3 이상 확장 시 스크립트 수정 필요
6. **`shareProcessNamespace: true`**
   - sidecar 가 메인 컨테이너 프로세스를 직접 조작 (pg_ctl) 가능하게 함
   - 보안 격리 측면에서 trade-off 인지 필요

---

## 13. 확장 / 마이그레이션 가이드

### 13.1. 다른 Namespace 에 동일 스택 추가 배포

```bash
./scripts/deploy.sh apply <new-ns>
# 또는 Helm
helm install postgresql-ha-second ./helm -n <new-ns> --create-namespace
```

각 ns 의 Lease/PVC/Service 는 독립이므로 충돌 없음. 단, **NodePort 30111/30112 는 클러스터 전역 unique** 라 두 인스턴스 동시 운용 시 NodePort 변경 필요 (Helm 의 `service.write.nodePort` / `service.read.nodePort` values).

### 13.2. StorageClass 변경

매니페스트만 수정하면 신규 배포에는 적용. **기존 PVC 의 `storageClassName` 은 immutable** 이므로 운영 중인 클러스터에 적용하려면:

1. 백업 확보 (`backup.sh run` 강제 트리거 또는 마지막 정기 백업 확인)
2. STS 삭제 (PVC 는 Retain 정책이라 보존됨)
3. PVC 삭제 (또는 새 이름으로)
4. 매니페스트 SC 변경 후 재배포
5. 첫 Pod 가 `init_primary()` 로 새 PGDATA 생성 → `restore-all.sh` 로 데이터 주입

### 13.3. PostgreSQL 마이너 업그레이드 (16.x → 16.y)

1. 신규 이미지 빌드/푸시 (`build.sh`)
2. `kubectl rollout restart sts/postgresql-ha`
3. PG 메이저 업그레이드(16→17 등) 는 별도 절차 필요 (pg_upgrade 또는 logical replication)

---

## 14. 참고 사항

- 본 스택은 외부 클러스터 매니저(Patroni / Stolon / Crunchy / Zalando) 를 쓰지 않습니다. **Kubernetes Lease 만으로 leader election** 합니다.
- 운영자가 자주 잊는 점: `RoleBinding.subjects[].namespace` 는 `kubectl -n` 으로 자동 치환되지 않습니다. **반드시 `deploy.sh` 사용** (또는 Helm).
- 인증서/비밀번호 도입은 후속 패치 예정 (현재는 폐쇄망 trust 전제).

---

## Sources

- PostgreSQL 16 Documentation — Streaming Replication: https://www.postgresql.org/docs/16/warm-standby.html#STREAMING-REPLICATION
- PostgreSQL 16 Documentation — pg_rewind: https://www.postgresql.org/docs/16/app-pgrewind.html
- PostgreSQL 16 Documentation — Replication Slots: https://www.postgresql.org/docs/16/warm-standby.html#STREAMING-REPLICATION-SLOTS
- Kubernetes — Lease (coordination.k8s.io/v1): https://kubernetes.io/docs/concepts/architecture/leases/
- Kubernetes — StatefulSet: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Kubernetes — ServiceAccount and RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Helm — Chart Best Practices: https://helm.sh/docs/chart_best_practices/
- Rook-Ceph — Block Storage (RBD): https://rook.io/docs/rook/latest-release/Storage-Configuration/Block-Storage-RBD/block-storage/
- Rook-Ceph — Shared Filesystem (CephFS): https://rook.io/docs/rook/latest-release/Storage-Configuration/Shared-Filesystem-CephFS/filesystem-storage/
