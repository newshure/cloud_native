FROM harbor.nova.office/library/base/trino-base:latest


LABEL maintainer="HaeDong 'https://www.haedongg.net'"

USER root

COPY --chown=1000:1000 files/trino-server-479 /opt/apps/trino-server-479
RUN ln -s /opt/apps/trino-server-479 /opt/trino && chown -R trino:trino /var/log/trino /opt/trino /opt/apps/trino-server-479



COPY --chown=1000:1000 files/bin /opt/trino/bin



USER trino

WORKDIR /opt/trino

EXPOSE 8080
EXPOSE 8443

ENTRYPOINT []

