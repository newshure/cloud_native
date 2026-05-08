# =============================================================================
# PostgreSQL 16.13 HA stack image
# - 전제: 베이스 이미지에 PostgreSQL 16.13 이 이미 설치되어 있음
# - 목적: HA 운영에 필요한 스크립트/도구만 추가
# =============================================================================
FROM harbor.nova.office/library/databases/postgresql-16:latest

USER 0

RUN dnf install -y --setopt=tsflags=nodocs \
      bash curl ca-certificates jq util-linux cronie gzip tzdata \
      glibc-langpack-ko findutils coreutils procps-ng --allowerasing \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN mkdir -p /opt/apps/postgresql-16.13  /opt/apps/postgresql-16.13/conf  /opt/apps/postgresql-16.13/backup && ln -s /opt/apps/postgresql-16.13 /opt/postgresql && \
    chown -R postgres:postgres /opt/apps/postgresql-16.13 /opt/postgresql &&  ln -s /usr/pgsql-16/bin /opt/postgresql/bin  && chmod 777 /run

COPY scripts/common.sh              /opt/postgresql/bin/common.sh
COPY scripts/entrypoint.sh          /opt/postgresql/bin/entrypoint.sh
COPY scripts/init-ha-bootstrap.sh   /opt/postgresql/bin/init-ha-bootstrap.sh
COPY scripts/role-manager.sh        /opt/postgresql/bin/role-manager.sh
COPY scripts/readiness.sh           /opt/postgresql/bin/readiness.sh
COPY scripts/liveness.sh            /opt/postgresql/bin/liveness.sh
COPY scripts/prestop.sh             /opt/postgresql/bin/prestop.sh
COPY scripts/backup.sh              /opt/postgresql/bin/backup.sh
COPY scripts/restore-all.sh         /opt/postgresql/bin/restore-all.sh
COPY scripts/deploy.sh              /opt/postgresql/bin/deploy.sh
COPY scripts/backup-cron.sh	    /opt/postgresql/bin/backup-cron.sh

RUN chmod 0755 /opt/postgresql/bin/common.sh \
                /opt/postgresql/bin/entrypoint.sh \
                /opt/postgresql/bin/init-ha-bootstrap.sh \
                /opt/postgresql/bin/role-manager.sh \
                /opt/postgresql/bin/readiness.sh \
                /opt/postgresql/bin/liveness.sh \
                /opt/postgresql/bin/prestop.sh \
                /opt/postgresql/bin/backup.sh \
                /opt/postgresql/bin/restore-all.sh \
                /opt/postgresql/bin/deploy.sh \
                /opt/postgresql/bin/backup-cron.sh \
 && chown 1000:1000 /opt/postgresql/bin/common.sh \
                    /opt/postgresql/bin/entrypoint.sh \
                    /opt/postgresql/bin/init-ha-bootstrap.sh \
                    /opt/postgresql/bin/role-manager.sh \
                    /opt/postgresql/bin/readiness.sh \
                    /opt/postgresql/bin/liveness.sh \
                    /opt/postgresql/bin/prestop.sh \
                    /opt/postgresql/bin/backup.sh \
                    /opt/postgresql/bin/restore-all.sh \
                    /opt/postgresql/bin/deploy.sh \
                    /opt/postgresql/bin/backup-cron.sh

ENV TZ=Asia/Seoul
RUN ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime

RUN curl --version >/dev/null \
 && jq --version >/dev/null \
 && flock --version >/dev/null \
 && (crond --version >/dev/null 2>&1 || command -v crond >/dev/null)

USER 1000
