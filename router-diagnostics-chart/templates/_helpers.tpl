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

{{/*
Whether container memory and CPU are read with the nodeMetrics collector: always under
mode: local, and under mode: job only when job.nodeStatsSource is apiServer. Renders "true"
or "false", and refuses a value or combination that has no meaning.
*/}}
{{- define "router-diagnostics-chart.useNodeMetricsCollector" -}}
{{- $source := .Values.job.nodeStatsSource | default "kubelet" }}
{{- if not (has $source (list "kubelet" "apiServer")) }}
{{- fail (printf "job.nodeStatsSource must be kubelet or apiServer, got %q" $source) }}
{{- end }}
{{- if and (eq .Values.mode "job") (eq $source "apiServer") (not .Values.job.collectNodeMetrics) }}
{{- fail "job.nodeStatsSource: apiServer needs job.collectNodeMetrics: true -- the nodeMetrics collector has nothing to fall back to." }}
{{- end }}
{{- if or (ne .Values.mode "job") (eq $source "apiServer") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Wraps a value in single quotes for the router-metrics shell script, escaping any single
quote inside it. Helm's squote alone leaves an embedded ' unescaped, which would end the
quoted string early.
*/}}
{{- define "router-diagnostics-chart.shellQuote" -}}
{{- . | toString | replace "'" "'\\''" | squote -}}
{{- end -}}
