{{/* vim: set filetype=mustache: */}}

{{/*
Common helpers for trino chart.
- fullname: 기본은 release name. release name == chart name 이면 chart name 만 사용.
  이렇게 하면 `helm install trino ./helm` 시 raw 매니페스트와 동일한 리소스
  이름이 만들어집니다.
*/}}

{{- define "trino.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "trino.fullname" -}}
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

{{- define "trino.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Standard labels applied to every resource */}}
{{- define "trino.labels" -}}
helm.sh/chart: {{ include "trino.chart" . }}
app.kubernetes.io/name: {{ include "trino.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: sql-engine
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* coordinator labels */}}
{{- define "trino.coordinatorLabels" -}}
{{ include "trino.labels" . }}
app: {{ .Values.componentNames.coordinatorName }}
{{- end -}}

{{- define "trino.coordinatorSelectorLabels" -}}
app: {{ .Values.componentNames.coordinatorName }}
{{- end -}}

{{/* worker labels */}}
{{- define "trino.workerLabels" -}}
{{ include "trino.labels" . }}
app: {{ .Values.componentNames.workerName }}
{{- end -}}

{{- define "trino.workerSelectorLabels" -}}
app: {{ .Values.componentNames.workerName }}
{{- end -}}

{{/*
Discovery URI for coordinator/worker config.
- coordinator 는 in-pod (localhost) 사용
- worker 는 service.namespace FQDN 사용
*/}}
{{- define "trino.coordinatorDiscoveryUri" -}}
{{- printf "http://%s:%d" .Values.componentNames.coordinatorService (int .Values.service.coordinator.httpPort) -}}
{{- end -}}

{{- define "trino.workerDiscoveryUri" -}}
{{- printf "http://%s.%s:%d" .Values.componentNames.coordinatorService .Release.Namespace (int .Values.service.coordinator.httpPort) -}}
{{- end -}}

{{/* Common downward-API env vars */}}
{{- define "trino.downwardEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
{{- end -}}

{{/* preStop graceful drain (Trino REST: SHUTTING_DOWN) */}}
{{- define "trino.preStop" -}}
exec:
  command:
    - /bin/sh
    - -c
    - |
      curl -s -X PUT \
        -d '"SHUTTING_DOWN"' \
        -H 'Content-type: application/json' \
        -H 'X-Trino-User: admin' \
        http://localhost:8080/v1/info/state
      sleep {{ . }}
{{- end -}}
