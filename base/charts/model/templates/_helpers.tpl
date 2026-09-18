{{- define "model.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "model.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "model.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "model.labels" -}}
app.kubernetes.io/name: {{ include "model.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}

{{/*
The S3 URI the KServe storage initializer fetches from.

Composed from the model's registry name and version so that the manifest can be
authored before the model exists. `storageUriOverride` bypasses the composition
for artefacts that did not come through scripts/promote-model.py.
*/}}
{{- define "model.storageUri" -}}
{{- if .Values.storageUriOverride -}}
{{- .Values.storageUriOverride -}}
{{- else -}}
{{- $name := required "model.name is required unless storageUriOverride is set" .Values.model.name -}}
{{- $version := required "model.version is required unless storageUriOverride is set" .Values.model.version -}}
{{- printf "s3://%s/%s/%s/%s/%v" .Values.storage.repository .Values.storage.ref .Values.storage.prefix $name $version -}}
{{- end -}}
{{- end -}}

{{/*
Names derived from the release rather than fixed, so that two models can be served
from one namespace without colliding on the ServiceAccount or the pull Secret.
*/}}
{{- define "model.serviceAccountName" -}}
{{- printf "%s-sa" (include "model.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "model.storageSecretName" -}}
{{- printf "%s-storage" (include "model.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
