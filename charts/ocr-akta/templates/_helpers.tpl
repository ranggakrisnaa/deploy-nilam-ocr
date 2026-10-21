{{- define "ocr-akta.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* The service this release renders; fails early on a missing or unknown name. */}}
{{- define "ocr-akta.component" -}}
{{- $component := required (printf "component is required: --set component=<%s>" (keys .Values.services | sortAlpha | join "|")) .Values.component }}
{{- if not (hasKey .Values.services $component) }}
{{- fail (printf "component %q is not one of services: %s" $component (keys .Values.services | sortAlpha | join ", ")) }}
{{- end }}
{{- $component }}
{{- end }}

{{/* Object name of any service. Argument: (list $ <service name>). */}}
{{- define "ocr-akta.fullnameOf" -}}
{{- $ := index . 0 }}
{{- $name := index . 1 }}
{{- $svc := index $.Values.services $name }}
{{- default (printf "%s-%s" (include "ocr-akta.name" $) $name) $svc.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ocr-akta.fullname" -}}
{{- include "ocr-akta.fullnameOf" (list . (include "ocr-akta.component" .)) }}
{{- end }}

{{- define "ocr-akta.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "ocr-akta.labels" -}}
helm.sh/chart: {{ include "ocr-akta.chart" . }}
{{ include "ocr-akta.selectorLabels" . }}
app.kubernetes.io/version: {{ include "ocr-akta.tag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nilam-ocr
{{- end }}

{{- define "ocr-akta.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ocr-akta.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ include "ocr-akta.component" . }}
{{- end }}

{{- define "ocr-akta.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ocr-akta.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "ocr-akta.tag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "ocr-akta.image" -}}
{{- $repo := printf "%s/%s" .Values.image.registry (required "image.repository is required" .Values.image.repository) }}
{{- if .Values.image.digest }}
{{- printf "%s@%s" $repo .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (include "ocr-akta.tag" .) }}
{{- end }}
{{- end }}

{{/*
Plain env of the rendered service, as a name -> value dict in YAML. Later entries win: built-ins, orchestration
(pipeline stages), APM, URLs of the upstreams, commonEnv, services.<name>.env. Empty values are dropped.
*/}}
{{- define "ocr-akta.envMap" -}}
{{- $component := include "ocr-akta.component" . }}
{{- $svc := index .Values.services $component }}
{{- $env := dict "PORT" ($svc.port | toString) "ENVIRONMENT" .Values.environment "HOME" "/tmp" }}
{{- if $svc.pipeline }}
{{- with .Values.orchestration }}
{{- $_ := set $env "ORCHESTRATION_CALLBACK_ENABLED" (ternary "true" "false" (eq (toString .callbackEnabled) "true")) }}
{{- $_ := set $env "ORCHESTRATION_URL" .url }}
{{- $_ := set $env "ORCHESTRATION_CALLBACK_PATH" .callbackPath }}
{{- $_ := set $env "ORCHESTRATION_CALLBACK_FORMAT" .callbackFormat }}
{{- $_ := set $env "ORCHESTRATION_TIMEOUT_SECONDS" (.timeoutSeconds | toString) }}
{{- end }}
{{- end }}
{{- with .Values.apm }}
{{- if .serverUrl }}
{{- $_ := set $env "ELASTIC_APM_SERVER_URL" .serverUrl }}
{{- $_ := set $env "ELASTIC_APM_SERVICE_NAME" (include "ocr-akta.fullname" $) }}
{{- $_ := set $env "ELASTIC_APM_ENVIRONMENT" (.environment | default $.Values.environment) }}
{{- $_ := set $env "ELASTIC_APM_TRANSACTION_SAMPLE_RATE" (.sampleRate | toString) }}
{{- end }}
{{- end }}
{{- range $svc.upstreams }}
{{- $upstream := index $.Values.services . }}
{{- $_ := set $env (printf "%s_SERVICE_URL" (upper .)) (printf "http://%s:%v" (include "ocr-akta.fullnameOf" (list $ .)) $upstream.port) }}
{{- end }}
{{- range $key, $value := .Values.commonEnv }}
{{- $_ := set $env $key ($value | toString) }}
{{- end }}
{{- range $key, $value := $svc.env }}
{{- $_ := set $env $key ($value | toString) }}
{{- end }}
{{- range $key, $value := $env }}
{{- if ne $value "" }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end }}
