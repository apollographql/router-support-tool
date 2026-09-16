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

{{/*
The Job's container command: run collection, then upload to job.storage if configured.
*/}}
{{- define "router-diagnostics.collectAndUploadScript" -}}
set -eu
support-bundle --load-cluster-specs
{{- if .Values.job.storage.provider }}
BUNDLE=$(ls -t support-bundle-*.tar.gz | head -n1)
{{- if eq .Values.job.storage.provider "s3" }}
{{- if .Values.job.storage.s3.forcePathStyle }}
mkdir -p /tmp/.aws-config
printf '[default]\ns3 =\n    addressing_style = path\n' > /tmp/.aws-config/config
export AWS_CONFIG_FILE=/tmp/.aws-config/config
{{- end }}
aws s3 cp "$BUNDLE" "s3://{{ .Values.job.storage.bucket }}/{{ .Values.job.storage.prefix }}$BUNDLE"{{ if .Values.job.storage.s3.region }} --region {{ .Values.job.storage.s3.region }}{{ end }}{{ if .Values.job.storage.s3.endpoint }} --endpoint-url {{ .Values.job.storage.s3.endpoint }}{{ end }}
{{- else if eq .Values.job.storage.provider "gcs" }}
gcloud storage cp "$BUNDLE" "gs://{{ .Values.job.storage.bucket }}/{{ .Values.job.storage.prefix }}$BUNDLE"{{ if .Values.job.storage.gcs.project }} --project={{ .Values.job.storage.gcs.project }}{{ end }}
{{- else if eq .Values.job.storage.provider "url" }}
set --
if [ -d /var/run/secrets/router-diagnostics-storage-headers ]; then
  for f in /var/run/secrets/router-diagnostics-storage-headers/*; do
    [ -f "$f" ] || continue
    set -- "$@" -H "$(basename "$f"): $(cat "$f")"
  done
fi
{{- range $k, $v := .Values.job.storage.url.headers }}
set -- "$@" -H {{ printf "%s: %s" $k $v | quote }}
{{- end }}
curl -sSf -X {{ .Values.job.storage.url.method | default "PUT" }} -T "$BUNDLE" "$@" {{ .Values.job.storage.url.endpoint | quote }}
{{- end }}
{{- end }}
{{- end -}}
