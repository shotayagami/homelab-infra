{{/*
共通ラベル
*/}}
{{- define "misskey.labels" -}}
app: misskey
app.kubernetes.io/name: misskey
app.kubernetes.io/instance: {{ .Values.instance.name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Web Pod 用 selector / label
*/}}
{{- define "misskey.webSelector" -}}
app: misskey
component: web
{{- end }}

{{/*
Redis Pod 用 selector / label
*/}}
{{- define "misskey.redisSelector" -}}
app: misskey
component: redis
{{- end }}

{{/*
必須 values の検証
*/}}
{{- define "misskey.validateRequired" -}}
{{- if not .Values.instance.name -}}{{ fail "instance.name is required" }}{{- end -}}
{{- if not .Values.instance.namespace -}}{{ fail "instance.namespace is required" }}{{- end -}}
{{- if not .Values.instance.url -}}{{ fail "instance.url is required" }}{{- end -}}
{{- if not .Values.instance.host -}}{{ fail "instance.host is required" }}{{- end -}}
{{- if not .Values.db.name -}}{{ fail "db.name is required" }}{{- end -}}
{{- if not .Values.db.user -}}{{ fail "db.user is required" }}{{- end -}}
{{- if and .Values.meilisearch.enabled (not .Values.meilisearch.apiKeyFromSecret) (not .Values.meilisearch.apiKey) -}}{{ fail "meilisearch.apiKey is required when meilisearch is enabled (unless apiKeyFromSecret=true)" }}{{- end -}}
{{- if and .Values.meilisearch.enabled (not .Values.meilisearch.index) -}}{{ fail "meilisearch.index is required when meilisearch is enabled" }}{{- end -}}
{{- if and .Values.ingress.enabled (not .Values.ingress.tlsSecretName) -}}{{ fail "ingress.tlsSecretName is required when ingress is enabled" }}{{- end -}}
{{- end }}
