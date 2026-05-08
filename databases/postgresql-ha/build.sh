#!/bin/bash

NOWDATE=$(date +%Y%m%d)

echo BUILDIN IMAGE
docker build -t harbor.nova.office/library/databases/postgresql:16.13-${NOWDATE} $(pwd)

echo PUSH IMAGE
docker push  harbor.nova.office/library/databases/postgresql:16.13-${NOWDATE}

echo PUSH LATEST TAG IMAGE
docker image tag harbor.nova.office/library/databases/postgresql:16.13-${NOWDATE} harbor.nova.office/library/databases/postgresql:latest
docker push harbor.nova.office/library/databases/postgresql:latest
