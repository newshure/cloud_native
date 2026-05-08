{{/* vim: set filetype=mustache: */}}

{{/*
Common helpers for postgresql-ha chart.
- fullname: 기본은 release name. release name == chart name 이면 chart name 만 사용.
  이렇게 하면 `helm install postgresql-ha ./helm` 시 raw 매니페스트와 동일한 리소스
  이름이 만들어집니다.
*/}}

{{- define "postgresql-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql-ha.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if eq .Release.Name $name -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "postgresql-ha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Standard labels applied to every resource */}}
{{- define "postgresql-ha.labels" -}}
helm.sh/chart: {{ include "postgresql-ha.chart" . }}
app: {{ include "postgresql-ha.fullname" . }}
app.kubernetes.io/name: {{ include "postgresql-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Pod selector labels (subset of full labels) */}}
{{- define "postgresql-ha.selectorLabels" -}}
app: {{ include "postgresql-ha.fullname" . }}
{{- end -}}

{{/* ServiceAccount name. priority: serviceAccount.name > componentNames.serviceAccount > <fullname>-sa */}}
{{- define "postgresql-ha.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else if .Values.componentNames.serviceAccount -}}
{{- .Values.componentNames.serviceAccount -}}
{{- else -}}
{{- printf "%s-sa" (include "postgresql-ha.fullname" .) -}}
{{- end -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Role / RoleBinding names — prefer componentNames; fallback to fullname + suffix */}}
{{- define "postgresql-ha.roleName" -}}
{{- default (printf "%s-role" (include "postgresql-ha.fullname" .)) .Values.componentNames.role -}}
{{- end -}}

{{- define "postgresql-ha.roleBindingName" -}}
{{- default (printf "%s-rb" (include "postgresql-ha.fullname" .)) .Values.componentNames.roleBinding -}}
{{- end -}}

{{/* Service names */}}
{{- define "postgresql-ha.headlessServiceName" -}}
{{- default (printf "%s-headless-service" (include "postgresql-ha.fullname" .)) .Values.service.headless.name -}}
{{- end -}}

{{- define "postgresql-ha.readServiceName" -}}
{{- default (printf "%s-read-service" (include "postgresql-ha.fullname" .)) .Values.service.read.name -}}
{{- end -}}

{{- define "postgresql-ha.writeServiceName" -}}
{{- default (printf "%s-write-service" (include "postgresql-ha.fullname" .)) .Values.service.write.name -}}
{{- end -}}

{{/* ConfigMap name */}}
{{- define "postgresql-ha.configMapName" -}}
{{- default (printf "%s-config" (include "postgresql-ha.fullname" .)) .Values.componentNames.configMap -}}
{{- end -}}

{{/* Backup PVC name */}}
{{- define "postgresql-ha.backupPvcName" -}}
{{- if .Values.persistence.backup.existingClaim -}}
{{- .Values.persistence.backup.existingClaim -}}
{{- else -}}
{{- default (printf "%s-backup-volume" (include "postgresql-ha.fullname" .)) .Values.componentNames.backupPvc -}}
{{- end -}}
{{- end -}}

{{/*
Common env vars injected to every container that touches postgres.
Centralized so all containers stay in sync.
*/}}
{{- define "postgresql-ha.commonEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- { name: POSTGRESQL_VERSION,                value: {{ .Values.postgresql.version | quote }} }
- { name: POSTGRESQL_BIN_DIR,                value: {{ .Values.postgresql.binDir | quote }} }
- { name: POSTGRESQL_CONF_DIR,               value: {{ .Values.postgresql.confDir | quote }} }
- { name: POSTGRESQL_DATA_DIR,               value: {{ .Values.postgresql.dataDir | quote }} }
- { name: POSTGRESQL_BACKUP_DIR,             value: {{ .Values.postgresql.backupDir | quote }} }
- { name: POSTGRESQL_LOG_DIR,                value: {{ .Values.postgresql.logDir | quote }} }
- { name: POSTGRESQL_SOCKET_DIR,             value: {{ .Values.postgresql.socketDir | quote }} }
- { name: POSTGRESQL_ENCODING,               value: {{ .Values.postgresql.encoding | quote }} }
- { name: POSTGRESQL_LOCALE,                 value: {{ .Values.postgresql.locale | quote }} }
- { name: POSTGRESQL_PORT,                   value: {{ .Values.postgresql.port | quote }} }
- { name: POSTGRESQL_LISTEN_ADDRESS,         value: {{ .Values.postgresql.listenAddress | quote }} }
- { name: POSTGRESQL_SUPERUSER,              value: {{ .Values.postgresql.superuser | quote }} }
- { name: POSTGRESQL_REPLICATION_USER,       value: {{ .Values.postgresql.replicationUser | quote }} }
- { name: POSTGRESQL_REPLICAS,               value: {{ .Values.replicaCount | quote }} }
- { name: POSTGRESQL_STS_NAME,               value: {{ include "postgresql-ha.fullname" . | quote }} }
- { name: POSTGRESQL_HEADLESS_SVC_NAME,      value: {{ include "postgresql-ha.headlessServiceName" . | quote }} }
- { name: POSTGRESQL_LEASE_NAME,             value: {{ .Values.postgresql.leaseName | quote }} }
- { name: POSTGRESQL_LEASE_DURATION_SEC,     value: {{ .Values.postgresql.leaseDurationSec | quote }} }
- { name: POSTGRESQL_MASTER_LABEL_VALUE,     value: {{ .Values.postgresql.masterLabelValue | quote }} }
- { name: POSTGRESQL_SYNC_NAMES,             value: {{ .Values.postgresql.syncNames | quote }} }
- { name: POSTGRESQL_ROLE_MGR_LOOP_SEC,      value: {{ .Values.postgresql.roleManagerLoopSec | quote }} }
- { name: POSTGRESQL_PEER_FAIL_THRESHOLD,    value: {{ .Values.postgresql.peerFailThreshold | quote }} }
- { name: POSTGRESQL_ISOLATION_THRESHOLD,    value: {{ .Values.postgresql.isolationThreshold | quote }} }
- { name: POSTGRESQL_RENEW_FAIL_THRESHOLD,   value: {{ .Values.postgresql.renewFailThreshold | quote }} }
- { name: POSTGRESQL_PEER_WAIT_SEC,          value: {{ .Values.postgresql.peerWaitSec | quote }} }
- { name: POSTGRESQL_BACKUP_RETENTION_DAYS,  value: {{ .Values.postgresql.backupRetentionDays | quote }} }
- { name: POSTGRESQL_BACKUP_SCHEDULE_DOW,    value: {{ .Values.postgresql.backupScheduleDow | quote }} }
- { name: POSTGRESQL_BACKUP_SCHEDULE_HOUR,   value: {{ .Values.postgresql.backupScheduleHour | quote }} }
- { name: POSTGRESQL_BACKUP_COMPRESSION_LEVEL, value: {{ .Values.postgresql.backupCompressionLevel | quote }} }
{{- end -}}

{{/* podAntiAffinity helper - preferred or required */}}
{{- define "postgresql-ha.affinity" -}}
{{- if .Values.customAffinity -}}
{{ toYaml .Values.customAffinity }}
{{- else if .Values.podAntiAffinity.enabled -}}
podAntiAffinity:
  {{- if eq .Values.podAntiAffinity.type "required" }}
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          {{- include "postgresql-ha.selectorLabels" . | nindent 10 }}
      topologyKey: {{ .Values.podAntiAffinity.topologyKey | quote }}
  {{- else }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: {{ .Values.podAntiAffinity.weight }}
      podAffinityTerm:
        labelSelector:
          matchLabels:
            {{- include "postgresql-ha.selectorLabels" . | nindent 12 }}
        topologyKey: {{ .Values.podAntiAffinity.topologyKey | quote }}
  {{- end }}
{{- end -}}
{{- end -}}
