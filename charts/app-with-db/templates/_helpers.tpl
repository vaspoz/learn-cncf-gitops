{{/*
Base name for all resources in this release.
*/}}
{{- define "app-with-db.name" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{/*
Name of the CloudNativePG Cluster.

This is also the name of the ServiceAccount CNPG creates for the Postgres pods,
which is what an EKS Pod Identity association must reference for S3 backups.
*/}}
{{- define "app-with-db.dbName" -}}
{{- printf "%s-db" (include "app-with-db.name" .) -}}
{{- end -}}

{{/*
Secret CNPG generates holding the application user's credentials.
Key `uri` is a ready-to-use connection string.
*/}}
{{- define "app-with-db.dbSecret" -}}
{{- printf "%s-app" (include "app-with-db.dbName" .) -}}
{{- end -}}

{{- define "app-with-db.objectStoreName" -}}
{{- printf "%s-backups" (include "app-with-db.dbName" .) -}}
{{- end -}}

{{- define "app-with-db.labels" -}}
app.kubernetes.io/name: {{ include "app-with-db.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "app-with-db.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app-with-db.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: app
{{- end -}}
