#!/bin/sh

REQ_NOFILE=131072
REQ_NPROC=128000

echo "Checking system resource limits..."

CUR_NOFILE=$(ulimit -n)
if [ "$CUR_NOFILE" -lt "$REQ_NOFILE" ]; then
    echo "[!] Current nofile ($CUR_NOFILE) is less than $REQ_NOFILE. Updating..."
    ulimit -n $REQ_NOFILE
else
    echo "[V] Nofile limit is already sufficient ($CUR_NOFILE)."
fi

CUR_NPROC=$(ulimit -u)
if [ "$CUR_NPROC" -lt "$REQ_NPROC" ]; then
    echo "[!] Current nproc ($CUR_NPROC) is less than $REQ_NPROC. Updating..."
    ulimit -u $REQ_NPROC
else
    echo "[V] Nproc limit is already sufficient ($CUR_NPROC)."
fi

CUR_MAP_COUNT=$(sysctl -n vm.max_map_count)
if [ "$CUR_MAP_COUNT" -lt 262144 ]; then
    echo "[!] vm.max_map_count ($CUR_MAP_COUNT) is low. Increasing to 262144..."
    sysctl -w vm.max_map_count=262144
fi

echo "Prerequisite check and setup completed."
