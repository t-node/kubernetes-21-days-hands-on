{{/*
Named templates. The leading underscore in the filename keeps this file from
being rendered as a manifest (28.4).

Call them with `include`, never with `template`, so the output can be piped:
    {{- include "mychart.labels" . | nindent 4 }}
*/}}

{{/* The chart name, overridable. */}}
{{- define "mychart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
A fully qualified name: <release>-<chart>, unless the release name already
contains the chart name (so `helm install mychart ./mychart` does not produce
`mychart-mychart`). Truncated to 63 characters -- the Kubernetes name limit.
*/}}
{{- define "mychart.fullname" -}}
{{- $name := include "mychart.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* The labels every object in this chart carries. */}}
{{- define "mychart.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
mychart.io/owner: {{ required "values.owner is required -- set it with --set owner=<team>" .Values.owner | quote }}
{{ include "mychart.selectorLabels" . }}
{{- end -}}

{{/*
Selector labels are a SUBSET of the labels above, and must never include
anything that changes between versions -- a Deployment's selector is immutable
(Day 04), so putting the chart version in here would break every upgrade.
*/}}
{{- define "mychart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mychart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
