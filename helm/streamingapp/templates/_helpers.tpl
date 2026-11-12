{{- define "sa.labels" -}}
app.kubernetes.io/part-of: streamingapp
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "sa.image" -}}
{{ .root.Values.image.registry }}/{{ .image }}:{{ .root.Values.image.tag }}
{{- end -}}

{{/* Public URL: value from values.yaml, else the load balancer hostname of the frontend Service */}}
{{- define "sa.publicUrl" -}}
{{- if .Values.publicUrl -}}
{{ .Values.publicUrl }}
{{- else -}}
{{- $svc := lookup "v1" "Service" .Release.Namespace "frontend" -}}
{{- if and $svc $svc.status.loadBalancer.ingress -}}
http://{{ (index $svc.status.loadBalancer.ingress 0).hostname }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Read a key from an existing Secret so passwords stay the same on upgrade */}}
{{- define "sa.secretValue" -}}
{{- $s := lookup "v1" "Secret" .ns "streamingapp-secrets" -}}
{{- if and $s (index $s.data .key) -}}
{{ index $s.data .key | b64dec }}
{{- else -}}
{{ randAlphaNum 32 }}
{{- end -}}
{{- end -}}

{{/* Opt pods out of CloudWatch Application Signals auto-instrumentation */}}
{{- define "sa.noOtel" -}}
instrumentation.opentelemetry.io/inject-nodejs: "false"
instrumentation.opentelemetry.io/inject-java: "false"
instrumentation.opentelemetry.io/inject-python: "false"
instrumentation.opentelemetry.io/inject-dotnet: "false"
{{- end -}}