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
Selector labels - can be overridden by commonLabels
*/}}
{{- define "hybriddatapipeline.selectorLabels" -}}
{{- $defaultLabels := dict "app.kubernetes.io/name" (include "hybriddatapipeline.name" .) "app.kubernetes.io/instance" .Release.Name -}}
{{- $commonLabels := .Values.hdp.commonLabels | default dict -}}
{{- $overrideLabels := dict -}}
{{- /* Check if commonLabels contains selector label overrides */ -}}
{{- if hasKey $commonLabels "app.kubernetes.io/name" -}}
{{- $_ := set $overrideLabels "app.kubernetes.io/name" (index $commonLabels "app.kubernetes.io/name") -}}
{{- end -}}
{{- if hasKey $commonLabels "app.kubernetes.io/instance" -}}
{{- $_ := set $overrideLabels "app.kubernetes.io/instance" (index $commonLabels "app.kubernetes.io/instance") -}}
{{- end -}}
{{- merge $overrideLabels $defaultLabels | toYaml -}}
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

{{/* Validate resource units for memory and CPU */}}
{{- define "hdp.resources.validate" -}}
{{- if not (regexMatch "^[0-9]+(Mi|Gi)$" .requests.memory) }}
{{- fail "Memory request must be specified in Mi or Gi, e.g., 512Mi or 1Gi" }}
{{- end }}
{{- if not (regexMatch "^[0-9]+(Mi|Gi)$" .limits.memory) }}
{{- fail "Memory limit must be specified in Mi or Gi, e.g., 512Mi or 1Gi" }}
{{- end }}
{{- if not (regexMatch "^[0-9]+(m)?$" .requests.cpu) }}
{{- fail "CPU request must be specified in cores or millicores, e.g., 500m or 1" }}
{{- end }}
{{- if not (regexMatch "^[0-9]+(m)?$" .limits.cpu) }}
{{- fail "CPU limit must be specified in cores or millicores, e.g., 1 or 500m" }}
{{- end }}
{{- end }}

{{/*
  Helper function to convert memory values with Mi or Gi suffix to megabytes (MB, base 1000).
  Usage: {{ include "toMegabytes" "512Mi" }} or {{ include "toMegabytes" "2Gi" }}
*/}}
{{- define "toMegabytes" -}}
{{- $val := . | toString -}}
{{- if hasSuffix "Gi" $val -}}
  {{- $val | trimSuffix "Gi" | int | mul 1024 -}}
{{- else if hasSuffix "Mi" $val -}}
  {{- $val | trimSuffix "Mi" | int -}}
{{- else -}}
  {{- $val | int -}}
{{- end -}}
{{- end }}

{{/*
This function merges standard chart labels, common labels, and specific labels.
Usage examples:
  # For pods:
  {{ include "hdp.labels.merge" (dict "commonLabels" .Values.hdp.commonLabels "specificLabels" .Values.hdp.podLabels "context" .) }}
  
  # For StatefulSet metadata:
  {{ include "hdp.labels.merge" (dict "commonLabels" .Values.hdp.commonLabels "context" .) }}
*/}}
{{- define "hdp.labels.merge" -}}
{{- $commonLabels := .commonLabels | default dict -}}
{{- $specificLabels := .specificLabels | default dict -}}
{{- $context := .context -}}
{{- $mergedLabels := dict -}}
{{- /* Start with standard chart labels from hybriddatapipeline.labels (lowest priority) */ -}}
{{- $standardLabels := include "hybriddatapipeline.labels" $context | fromYaml -}}
{{- range $key, $value := $standardLabels -}}
{{- $_ := set $mergedLabels $key $value -}}
{{- end -}}
{{- /* Add common labels (medium priority - can override standard labels) */ -}}
{{- if $commonLabels -}}
{{- range $key, $value := $commonLabels -}}
{{- $_ := set $mergedLabels $key $value -}}
{{- end -}}
{{- end -}}
{{- /* Add specific labels (highest priority - will override common and standard labels) */ -}}
{{- if $specificLabels -}}
{{- range $key, $value := $specificLabels -}}
{{- $_ := set $mergedLabels $key $value -}}
{{- end -}}
{{- end -}}
{{- $mergedLabels | toYaml -}}
{{- end }}

{{/*
Merge annotations with proper precedence:
1. Base annotations (lowest priority - often chart-specific defaults)
2. Common annotations from Values.hdp.commonAnnotations (medium priority)
3. Specific annotations from resource-specific configuration (highest priority)

Usage:
  annotations: {{- include "hdp.annotations.merge" (dict "commonAnnotations" .Values.hdp.commonAnnotations "specificAnnotations" .Values.hdp.hdpingressconfiguration.annotations "baseAnnotations" $baseAnnotations "context" .) | nindent 4 }}
*/}}
{{- define "hdp.annotations.merge" -}}
{{- $baseAnnotations := .baseAnnotations | default dict -}}
{{- $commonAnnotations := .commonAnnotations | default dict -}}
{{- $specificAnnotations := .specificAnnotations | default dict -}}
{{- $mergedAnnotations := dict -}}
{{- /* Handle baseAnnotations - could be dict or string from include */ -}}
{{- if $baseAnnotations -}}
{{- if kindIs "string" $baseAnnotations -}}
{{- $baseAnnotations = $baseAnnotations | fromYaml -}}
{{- end -}}
{{- /* Merge base annotations first (lowest priority) */ -}}
{{- range $key, $value := $baseAnnotations -}}
{{- $_ := set $mergedAnnotations $key $value -}}
{{- end -}}
{{- end -}}
{{- /* Add common annotations (medium priority - can override base annotations) */ -}}
{{- if $commonAnnotations -}}
{{- range $key, $value := $commonAnnotations -}}
{{- $_ := set $mergedAnnotations $key $value -}}
{{- end -}}
{{- end -}}
{{- /* Add specific annotations (highest priority - will override common and base annotations) */ -}}
{{- if $specificAnnotations -}}
{{- range $key, $value := $specificAnnotations -}}
{{- $_ := set $mergedAnnotations $key $value -}}
{{- end -}}
{{- end -}}
{{- $mergedAnnotations | toYaml -}}
{{- end }}

{{/*
Generate base annotations for HDP Ingress based on ingress controller type and configuration
Returns YAML string of base annotations specific to the configured ingress controller (AGIC or HAProxy)
*/}}
{{- define "hdp.ingress.baseAnnotations" -}}
{{- $baseAnnotations := dict -}}
{{- if .Values.hdp.hdpingressconfiguration.haproxy.enabled -}}
{{- $_ := set $baseAnnotations "haproxy.org/forwarded-for" "true" -}}
{{- $_ := set $baseAnnotations "haproxy.org/load-balance" "roundrobin" -}}
{{- $_ := set $baseAnnotations "haproxy.org/timeout-check" (.Values.hdp.hdpingressconfiguration.timeout | default 300 | toString) -}}
{{- $_ := set $baseAnnotations "haproxy.org/timeout-server" (.Values.hdp.hdpingressconfiguration.timeout | default 300 | toString) -}}
{{- else if .Values.hdp.hdpingressconfiguration.agic.enabled -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/cookie-based-affinity" "true" -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/session-affinity-cookie-name" "HDP-SESSION" -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/request-timeout" (.Values.hdp.hdpingressconfiguration.timeout | default 300 | toString) -}}
{{- if .Values.hdp.hdpingressconfiguration.tls.enabled -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/ssl-redirect" "true" -}}
{{- end -}}
{{- end -}}
{{- $baseAnnotations | toYaml -}}
{{- end }}

{{/*
Generate base annotations for HDP Service based on ingress controller type and configuration
Returns YAML string of base annotations specific to the configured ingress controller (AGIC or HAProxy)
*/}}
{{- define "hdp.service.baseAnnotations" -}}
{{- $baseAnnotations := dict -}}
{{- if .Values.hdp.hdpingressconfiguration.haproxy.enabled -}}
{{- $_ := set $baseAnnotations "haproxy.org/affinity" "cookie" -}}
{{- $_ := set $baseAnnotations "haproxy.org/cookie-persistence" "HDP-SESSION" -}}
{{- $_ := set $baseAnnotations "haproxy.org/check" (.Values.hdp.services.hdpService.check | toString) -}}
{{- $_ := set $baseAnnotations "haproxy.org/check-http" (printf "HEAD %s" .Values.hdp.services.hdpService.checkPath) -}}
{{- $_ := set $baseAnnotations "haproxy.org/check-interval" (.Values.hdp.services.hdpService.checkInterval | toString) -}}
{{- else if .Values.hdp.hdpingressconfiguration.agic.enabled -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-path" (.Values.hdp.services.hdpService.check | toString) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-protocol" (printf "HEAD %s" .Values.hdp.services.hdpService.checkPath) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-interval" (.Values.hdp.services.hdpService.checkInterval | toString) -}}
{{- end -}}
{{- $baseAnnotations | toYaml -}}
{{- end }}

{{/*
Generate base annotations for HDP Notification Service based on ingress controller type and configuration
Returns YAML string of base annotations specific to the configured ingress controller (AGIC or HAProxy)
*/}}
{{- define "hdp.notificationService.baseAnnotations" -}}
{{- $baseAnnotations := dict -}}
{{- if .Values.hdp.hdpingressconfiguration.haproxy.enabled -}}
{{- $_ := set $baseAnnotations "haproxy.org/check" (.Values.hdp.services.notificationService.check | toString) -}}
{{- $_ := set $baseAnnotations "haproxy.org/check-http" (printf "HEAD %s" .Values.hdp.services.notificationService.checkPath) -}}
{{- $_ := set $baseAnnotations "haproxy.org/check-interval" (.Values.hdp.services.notificationService.checkInterval | toString) -}}
{{- $_ := set $baseAnnotations "haproxy.org/route-acl" (printf "path_end -i %s" .Values.hdp.services.notificationService.aclPath) -}}
{{- else if .Values.hdp.hdpingressconfiguration.agic.enabled -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-path" (.Values.hdp.services.notificationService.check | toString) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-protocol" (printf "HEAD %s" .Values.hdp.services.notificationService.checkPath) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-interval" (.Values.hdp.services.notificationService.checkInterval | toString) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/request-routing-rules" "PathBasedRouting" -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/backend-path-prefix" .Values.hdp.services.notificationService.aclPath -}}
{{- end -}}
{{- $baseAnnotations | toYaml -}}
{{- end }}

{{/*
Generate base annotations for HDP OPA Service based on ingress controller type and configuration
Takes an ordinal parameter for dynamic path generation
Returns YAML string of base annotations specific to the configured ingress controller (AGIC or HAProxy)
Usage: include "hdp.opaService.baseAnnotations" (dict "context" . "ordinal" $ordinal)
*/}}
{{- define "hdp.opaService.baseAnnotations" -}}
{{- $context := .context -}}
{{- $ordinal := .ordinal -}}
{{- $opaPath := (printf "%s-%s-%d" $context.Release.Name $context.Values.hdp.services.hdpService.name $ordinal) -}}
{{- $baseAnnotations := dict -}}
{{- if $context.Values.hdp.hdpingressconfiguration.haproxy.enabled -}}
{{- $_ := set $baseAnnotations "haproxy.org/check" ($context.Values.hdp.services.opAccessorService.check | toString) -}}
{{- $_ := set $baseAnnotations "haproxy.org/check-http" (printf "HEAD %s" $context.Values.hdp.services.opAccessorService.checkPath) -}}
{{- $_ := set $baseAnnotations "haproxy.org/check-interval" ($context.Values.hdp.services.opAccessorService.checkInterval | toString) -}}
{{- $_ := set $baseAnnotations "haproxy.org/route-acl" (printf "path_beg -i %s_%s" $context.Values.hdp.services.opAccessorService.aclPath $opaPath) -}}
{{- else if $context.Values.hdp.hdpingressconfiguration.agic.enabled -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-path" ($context.Values.hdp.services.opAccessorService.check | toString) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-protocol" (printf "HEAD %s" $context.Values.hdp.services.opAccessorService.checkPath) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/probe-interval" ($context.Values.hdp.services.opAccessorService.checkInterval | toString) -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/request-routing-rules" "PathBasedRouting" -}}
{{- $_ := set $baseAnnotations "appgw.ingress.kubernetes.io/backend-path-prefix" (printf "%s_%s" $context.Values.hdp.services.opAccessorService.aclPath $opaPath) -}}
{{- end -}}
{{- $baseAnnotations | toYaml -}}
{{- end }}

{{/*
Validate PDB configuration for HDP
*/}}
{{- define "hybriddatapipeline.validatePDB" -}}
{{- if .Values.hdp.pdb.create }}
  {{- if and .Values.hdp.pdb.minAvailable .Values.hdp.pdb.maxUnavailable }}
    {{- fail "PodDisruptionBudget cannot have both minAvailable and maxUnavailable set. Please specify only one." }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Generate smart PDB defaults based on replica count for HDP
*/}}
{{- define "hybriddatapipeline.pdbSmartDefaults" -}}
{{- if ge (int .Values.hdp.replicaCount) 3 }}
maxUnavailable: 1
{{- else if eq (int .Values.hdp.replicaCount) 2 }}
minAvailable: 1
{{- else }}
minAvailable: 1
{{- end }}
{{- end }}


