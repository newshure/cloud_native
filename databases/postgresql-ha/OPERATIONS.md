# PostgreSQL 16 HA 운영 매뉴얼

## 1. 목적

이 문서는 Kubernetes 위에서 동작하는 PostgreSQL 16 HA 구성을 **유지보수자 관점**에서 설명합니다.

핵심 운영 원칙은 아래와 같습니다.

1. **Read 유지 우선**
2. **자동 복구 우선**
3. **자동 복구 불가 시 reset + backup 전체 복구 허용**

---

## 2. 파일 구성

- `Dockerfile`
  - 기존 PostgreSQL 16.13 설치 이미지를 베이스로 사용
  - HA 동작용 스크립트와 필수 도구만 추가
- `manifests/*.yaml`
  - 배포 리소스 정의
- `scripts/common.sh`
  - 공통 환경변수 / 공통 함수
- `scripts/init-ha-bootstrap.sh`
  - 최초 부팅 / 재기동 시 Primary/Replica 분기
- `scripts/role-manager.sh`
  - Lease 유지, 승격/강등, role 라벨 관리
- `scripts/backup.sh`
  - 정기 백업 / catch-up 백업
- `scripts/restore-all.sh`
  - 최종 수동 복구용 전체 복원
- `scripts/deploy.sh`
  - namespace 렌더링 + kubectl apply 보조

---

## 3. 배포 전 체크리스트

### 3.1. 이미지 준비

1. 현재 디렉터리 기준으로 이미지 빌드
2. 사설 레지스트리에 push
3. StatefulSet 의 image 값이 해당 이미지를 가리키는지 확인
4. `imagePullPolicy: Always` 유지 확인

### 3.2. 스토리지 확인

1. Data PVC 용 StorageClass 준비
2. Backup PVC 용 RWX StorageClass 준비
3. backup PVC 는 두 Pod 가 동시에 접근 가능해야 함

### 3.3. 네트워크 / 보안 확인

현재 예제는 `trust` 인증입니다.

따라서 아래 조건이 필수입니다.

1. 외부 직접 노출 금지
2. 네트워크 정책 또는 사설망 통제
3. write-service 는 기본 ClusterIP 유지 권장

---

## 4. 배포 절차

### 4.1. namespace 렌더링

`RoleBinding.subjects[].namespace` 는 `kubectl -n` 만으로 자동 변경되지 않습니다.
그래서 반드시 `deploy.sh` 로 렌더링 후 배포합니다.

예시:

```bash
./scripts/deploy.sh render databases /tmp/postgresql-ha-rendered
kubectl apply -n databases -f /tmp/postgresql-ha-rendered
```

또는:

```bash
./scripts/deploy.sh apply databases
```

### 4.2. 배포 후 확인

```bash
kubectl -n databases get pods -o wide
kubectl -n databases get svc
kubectl -n databases get lease postgres-primary-lease -o yaml
kubectl -n databases get pods -L role
```

확인 포인트:

1. Pod 2개가 모두 Running
2. 한 Pod 만 `role=master`
3. read-service endpoint 는 최대한 유지
4. write-service endpoint 는 master 1개만 연결

---

## 5. 정상 상태 점검

### 5.1. Primary 확인

```bash
kubectl -n databases get pods -l role=master
```

### 5.2. PostgreSQL 내부 확인

```bash
PRIMARY=$(kubectl -n databases get pods -l role=master -o jsonpath='{.items[0].metadata.name}')
kubectl -n databases exec -it "$PRIMARY" -c postgresql -- psql -U postgres -At -c "SELECT pg_is_in_recovery();"
```

결과:

- `f` 이면 Primary
- `t` 이면 Replica

### 5.3. 복제 상태 확인

Primary 에서:

```bash
kubectl -n databases exec -it "$PRIMARY" -c postgresql -- \
  psql -U postgres -d postgres -x -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

---

## 6. 장애 대응 원칙

### 6.1. 자동 복구 우선순위

1. Lease 기반 failover
2. 기존 Primary 재시작 시 `pg_rewind`
3. `pg_rewind` 실패 시 `pg_basebackup`
4. 그것도 어렵다면 유지보수자가 reset 후 `restore-all.sh`

### 6.2. Read 우선 정책

이 구성은 **Read 유지 우선**입니다.

따라서 아래는 의도된 동작입니다.

1. readiness 는 streaming 상태를 강하게 보지 않음
2. Replica 가 stale 이어도 read endpoint 에 남을 수 있음
3. write 안전성은 Lease 와 role-manager 로 제어

즉, 장애 중 짧은 시간 동안 **read 는 유지되지만 최신성은 완벽하지 않을 수 있음**을 운영자가 이해해야 합니다.

---

## 7. 롤링 재시작 절차

반드시 한 번에 하나씩 확인합니다.

```bash
kubectl -n databases rollout restart sts/postgresql
kubectl -n databases rollout status sts/postgresql
```

확인 포인트:

1. `podManagementPolicy: OrderedReady`
2. 항상 최소 1개 Pod 는 Ready 유지
3. read-service endpoint 가 비지 않는지 확인

---

## 8. 백업 확인 절차

### 8.1. 백업 파일 확인

```bash
kubectl -n databases exec -it postgresql-0 -c backup-cron -- ls -al /opt/postgresql/backup/postgresql-0/scheduled
kubectl -n databases exec -it postgresql-1 -c backup-cron -- ls -al /opt/postgresql/backup/postgresql-1/scheduled
```

백업 산출물:

- `*_globals_<timestamp>.sql`
- `*_manifest_<timestamp>.txt`
- `*_<dbname>_<timestamp>.dump`

### 8.2. 백업 논리

- globals 먼저 백업
- DB 별 custom format dump 생성
- manifest 로 같은 시점의 DB 목록 보존
- catch-up 으로 누락 주간 백업 보완

---

## 9. 자동 복구 실패 시 수동 복구

### 9.1. 권장 순서

1. 현재 어떤 Pod 가 master 인지 확인
2. 자동 failback 로그 확인
3. `pg_rewind` 실패 여부 확인
4. slot invalidation 여부 확인
5. 필요 시 해당 Pod 의 data PVC 초기화 후 재기동

### 9.2. Replica 재생성 수준의 수동 복구

특정 Replica 만 다시 붙이면 되는 경우:

1. 대상 Pod scale down 또는 삭제
2. 해당 Pod 의 data PVC 정리 여부 판단
3. 재기동 시 `init-ha-bootstrap.sh` 가 fresh basebackup 수행하도록 유도

---

## 10. 최종 복구: reset + backup 전체 복원

이 절차는 **자동 self-fix 가 어렵다고 유지보수자가 판단했을 때만** 사용합니다.

### 10.1. 개념

1. 신규 Primary 를 깨끗하게 initdb
2. PostgreSQL 기동
3. 최신 백업 세트를 선택
4. `restore-all.sh` 로 globals + DB 전체 복원
5. Replica 는 이후 새 Primary 기준으로 다시 붙임

### 10.2. 절차 예시

#### Step 1. 서비스 영향 통제

- write 트래픽 차단
- 필요 시 앱 정지
- 기존 Pod 상태 기록

#### Step 2. 신규 Primary 확보

- 한 Pod 를 기준으로 clean 상태 확보
- 필요 시 PVC reset
- init 완료 후 postgres 단독 기동 확인

#### Step 3. 백업 세트 선택

백업 디렉터리 예:

```bash
/opt/postgresql/backup/postgresql-0/scheduled
```

최신 세트는 아래 파일 조합입니다.

- `globals`
- `manifest`
- manifest 에 기록된 각 DB dump

#### Step 4. 전체 복원

```bash
/opt/postgresql/bin/restore-all.sh /opt/postgresql/backup/postgresql-0
```

또는 scheduled 디렉터리 직접 지정:

```bash
/opt/postgresql/bin/restore-all.sh /opt/postgresql/backup/postgresql-0/scheduled
```

#### Step 5. Replica 재합류

- 다른 Pod 는 초기화 후 다시 기동
- `init-ha-bootstrap.sh` 가 새 Primary 기준으로 basebackup 수행

---

## 11. 유지보수자가 반드시 알아야 할 예외

### 11.1. RoleBinding namespace 예외

`kubectl apply -n <ns>` 만으로는 RoleBinding subject namespace 가 바뀌지 않습니다.
반드시 `deploy.sh render/apply` 사용이 안전합니다.

### 11.2. trust 인증 예외

이 구성은 운영 단순화를 위해 trust 를 사용합니다.
반드시 네트워크 레벨에서 보호해야 합니다.

### 11.3. Read 우선 예외

Read 유지가 최우선이라 stale read 가능성이 있습니다.
강한 read-after-write 일관성이 중요한 서비스면 별도 라우팅 정책이 필요합니다.

### 11.4. backup 은 논리 백업

현재 기본 백업은 dump 기반입니다.
대용량 DB / 짧은 RTO 가 필요하면 WAL archive 기반 PITR 을 추가 검토해야 합니다.

---

## 12. 운영자가 자주 보는 로그

```bash
kubectl -n databases logs postgresql-0 -c postgresql
kubectl -n databases logs postgresql-0 -c role-manager
kubectl -n databases logs postgresql-0 -c backup-cron
kubectl -n databases logs postgresql-1 -c postgresql
kubectl -n databases logs postgresql-1 -c role-manager
kubectl -n databases logs postgresql-1 -c backup-cron
```

중점 확인 문자열:

- `Mode A`
- `Mode B`
- `Mode C`
- `Mode D`
- `Lease acquired`
- `Demote`
- `SELF-FENCE`
- `pg_rewind`
- `pg_basebackup`
- `백업 완료`
