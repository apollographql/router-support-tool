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

{{/*
mode: job's default pod annotations (disable Istio/Linkerd sidecar injection) — the
single source of truth for both templates below, so the disabling values only ever
need to be written in one place.
*/}}
{{- define "router-diagnostics.jobPodAnnotationDefaults" -}}
sidecar.istio.io/inject: "false"
linkerd.io/inject: disabled
{{- end -}}

{{/*
The defaults above, merged with job.podAnnotations — values set there override these
defaults, which fill in anything left unset.
*/}}
{{- define "router-diagnostics.jobPodAnnotations" -}}
{{- $defaults := include "router-diagnostics.jobPodAnnotationDefaults" . | fromYaml }}
{{- $custom := .Values.job.podAnnotations | default dict }}
{{- merge (dict) $custom $defaults | toYaml }}
{{- end -}}

{{/*
Render-time fact for meta.json's sidecar_injection_disabled field: true only if both
default-disabling annotations are still in effect after the merge above. Overriding
either one back to enabled means injection is not fully disabled.
*/}}
{{- define "router-diagnostics.sidecarInjectionDisabled" -}}
{{- $defaults := include "router-diagnostics.jobPodAnnotationDefaults" . | fromYaml }}
{{- $merged := include "router-diagnostics.jobPodAnnotations" . | fromYaml }}
{{- $istio := index $merged "sidecar.istio.io/inject" | toString }}
{{- $linkerd := index $merged "linkerd.io/inject" | toString }}
{{- if and (eq $istio (index $defaults "sidecar.istio.io/inject" | toString)) (eq $linkerd (index $defaults "linkerd.io/inject" | toString)) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}
