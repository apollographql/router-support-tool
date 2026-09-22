{{- define "router-diagnostics.routerServiceName" -}}
{{- $svc := "" }}
{{- $selector := .Values.selector | default "app.kubernetes.io/name=router" }}
{{- $key := index (splitList "=" $selector) 0 }}
{{- $value := index (splitList "=" $selector) 1 }}
{{- $services := (lookup "v1" "Service" .Values.namespace "").items }}
{{- range $services }}
  {{- if eq (index .metadata.labels $key) $value }}
    {{- $svc = .metadata.name }}
  {{- end }}
{{- end }}
{{- $svc }}
{{- end -}}

{{/*
Finds the internal Kubernetes DNS host for the router-metrics collector by doing the following:

1. Searches the current namespace for a Service matching '.Values.selector'.
2. If found, returns its full internal FQDN (e.g., service.namespace.svc.cluster.local).
3. If not found, returns an empty string ("") to gracefully disable the metrics target.
*/}}
{{- define "router-diagnostics.metricsTargetHost" -}}
{{- $selector := .Values.selector | default "app.kubernetes.io/name=router" }}
{{- $parts := splitList "=" $selector }}
{{- $key := index $parts 0 }}
{{- $value := index $parts 1 }}
{{- $host := "" }}
{{- $services := (lookup "v1" "Service" .Values.namespace "").items }}
{{- range $services }}
  {{- if and .spec.selector (eq (index .spec.selector $key) $value) }}
    {{- $host = printf "%s.%s.svc.cluster.local" .metadata.name $.Values.namespace }}
  {{- end }}
{{- end }}
{{- $host }}
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

{{/*
job.storage has three credential paths: a customer-supplied existingSecret, a
static credential value templated into a chart-created Secret, or neither (IRSA/Workload
Identity via job.serviceAccount.annotations, resolved automatically at the API-call
level with no Secret at all). Setting both existingSecret and a static value at once is
most likely a mistake and will fail at `helm install`/`template`.
*/}}
{{- define "router-diagnostics.storageCredentialCheck" -}}
{{- $hasStaticCreds := or (and .Values.job.storage.s3.accessKeyId .Values.job.storage.s3.secretAccessKey) .Values.job.storage.gcs.credentialsJson }}
{{- if and .Values.job.storage.existingSecret $hasStaticCreds }}
{{- fail "job.storage.existingSecret and a static job.storage.s3/gcs credential are mutually exclusive -- set at most one." }}
{{- end }}
{{- end -}}

{{/*
The Secret name job.yaml mounts credentials/headers from. Empty when neither an
existingSecret nor a static s3/gcs credential is set (the IRSA/Workload Identity path,
or provider: url with no existingSecret).
*/}}
{{- define "router-diagnostics.storageSecretName" -}}
{{- include "router-diagnostics.storageCredentialCheck" . -}}
{{- if .Values.job.storage.existingSecret -}}
{{- .Values.job.storage.existingSecret -}}
{{- else if or (and .Values.job.storage.s3.accessKeyId .Values.job.storage.s3.secretAccessKey) .Values.job.storage.gcs.credentialsJson -}}
router-diagnostics-storage-credentials
{{- end -}}
{{- end -}}
