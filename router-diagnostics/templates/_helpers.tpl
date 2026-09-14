{{- define "router-diagnostics.routerServiceName" -}}
{{- $svc := "" }}
{{- $services := (lookup "v1" "Service" .Values.namespace "").items }}
{{- range $services }}
  {{- if eq (index .metadata.labels "app.kubernetes.io/name") "router" }}
    {{- $svc = .metadata.name }}
  {{- end }}
{{- end }}
{{- $svc }}
{{- end -}}
