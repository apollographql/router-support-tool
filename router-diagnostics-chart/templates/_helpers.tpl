{{/*
Renders one http collector per router pod matching the selector when the collection
job runs in-cluster and can reach pod IPs directly. Pod IPs are resolved at Helm 
render time.
*/}}
{{- define "router-diagnostics-chart.routerMetricsCollectors" -}}
{{- $selector := .Values.selector | default "app.kubernetes.io/name=router" }}
{{- $key := index (splitList "=" $selector) 0 }}
{{- $value := index (splitList "=" $selector) 1 }}
{{- $metricsPort := .Values.metricsPort | default 9090 }}
{{- range (lookup "v1" "Pod" .Values.namespace "").items }}
{{- if eq (index .metadata.labels $key) $value }}
- http:
    name: router-metrics-{{ .metadata.name }}
    get:
      url: http://{{ .status.podIP }}:{{ $metricsPort }}/metrics
{{- end }}
{{- end }}
{{- end -}}

{{/*
mode: job's default pod annotations (disable Istio/Linkerd sidecar injection) — the
single source of truth for both templates below, so the disabling values only ever
need to be written in one place.
*/}}
{{- define "router-diagnostics-chart.jobPodAnnotationDefaults" -}}
sidecar.istio.io/inject: "false"
linkerd.io/inject: disabled
{{- end -}}

{{/*
The defaults above, merged with job.podAnnotations — values set there override these
defaults, which fill in anything left unset.
*/}}
{{- define "router-diagnostics-chart.jobPodAnnotations" -}}
{{- $defaults := include "router-diagnostics-chart.jobPodAnnotationDefaults" . | fromYaml }}
{{- $custom := .Values.job.podAnnotations | default dict }}
{{- merge (dict) $custom $defaults | toYaml }}
{{- end -}}

{{/*
Render-time fact for meta.json's sidecar_injection_disabled field: true only if both
default-disabling annotations are still in effect after the merge above. Overriding
either one back to enabled means injection is not fully disabled.
*/}}
{{- define "router-diagnostics-chart.sidecarInjectionDisabled" -}}
{{- $defaults := include "router-diagnostics-chart.jobPodAnnotationDefaults" . | fromYaml }}
{{- $merged := include "router-diagnostics-chart.jobPodAnnotations" . | fromYaml }}
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
{{- define "router-diagnostics-chart.storageCredentialCheck" -}}
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
{{- define "router-diagnostics-chart.storageSecretName" -}}
{{- include "router-diagnostics-chart.storageCredentialCheck" . -}}
{{- if .Values.job.storage.existingSecret -}}
{{- .Values.job.storage.existingSecret -}}
{{- else if or (and .Values.job.storage.s3.accessKeyId .Values.job.storage.s3.secretAccessKey) .Values.job.storage.gcs.credentialsJson -}}
router-diagnostics-storage-credentials
{{- end -}}
{{- end -}}
