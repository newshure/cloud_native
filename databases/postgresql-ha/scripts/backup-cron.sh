#/bin/bash 


set -e

/bin/bash /opt/postgresql/bin/backup.sh startup-check &

last_run_date=""
target_hour=$(printf "%02d" "${POSTGRESQL_BACKUP_SCHEDULE_HOUR}")

while true; do
  dow=$(date +%u)
  hour=$(date +%H)
  minute=$(date +%M)
  today=$(date +%Y%m%d)

if [[ "$dow" == "${POSTGRESQL_BACKUP_SCHEDULE_DOW}" ]] \
  && [[ "$hour" == "$target_hour" ]] \
  && [[ "$minute" == "00" ]] \
  && [[ "$today" != "$last_run_date" ]]; then
  echo "[bk-sched-$(date '+%Y-%m-%d %H:%M:%S')] Trigger backup"
  /bin/bash /opt/postgresql/bin/backup.sh run
  last_run_date="$today"
fi

sleep 30

done
