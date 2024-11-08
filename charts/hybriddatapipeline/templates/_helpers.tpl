{{/*
Expand the name of the chart.
*/}}
{{- define "hybriddatapipeline.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "hybriddatapipeline.namespace" -}}
  {{- printf "%s" .Release.Namespace -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "hybriddatapipeline.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hybriddatapipeline.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hybriddatapipeline.labels" -}}
helm.sh/chart: {{ include "hybriddatapipeline.chart" . }}
{{ include "hybriddatapipeline.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hybriddatapipeline.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hybriddatapipeline.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "hybriddatapipeline.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "hybriddatapipeline.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Retrieve and decode a value from a Kubernetes Secret.
Usage: {{ include "hybriddatapipeline.secretValue" (dict "secretName" "your-secret-name" "key" "your-key" "namespace" "your-namespace" "context" "your-context") }}
*/}}
{{- define "hybriddatapipeline.secretValue" -}}
{{- $secretName := printf "%s" .secretName -}}
{{- $key := printf "%s" .key -}}
{{- $context := .context -}}
{{- $namespace :=  $context.Release.Namespace -}}
{{- if and $secretName $key $namespace -}}
  {{- $secret := lookup "v1" "Secret" $namespace $secretName -}}
  {{- if $secret -}}
    {{- $value := index $secret.data $key | b64dec -}}
    {{- if (eq $value "") -}}
      {{- printf "Value is empty for the key %s" $key   -}}
    {{- else -}}
        {{- $value -}}     
    {{- end -}}  
  {{- else -}}
    {{- printf "Secret %s is not available in the %s namespace" $secretName  $namespace -}}
  {{- end -}}
{{- else -}}
  {{- printf "Missing one of the requried parameter secret | key | namespace" -}}
{{- end -}}
{{- end -}}

{{/*
Convert a boolean value to yes or no.
Usage: {{ include "boolToYesNo" "value" }}
*/}}
{{- define "boolToYesNo" -}}
{{- if . -}}
yes
{{- else -}}
no
{{- end -}}
{{- end -}}
