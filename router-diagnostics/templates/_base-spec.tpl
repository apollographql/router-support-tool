{{/*
The base collection spec (support-bundle/base_spec.yaml), templated with this chart's
values.
*/}}
{{- define "router-diagnostics.spec" -}}
apiVersion: troubleshoot.sh/v1beta2
kind: SupportBundle
metadata:
  name: router-diagnostics-base
spec:
  collectors:
    - clusterResources:
        collectorName: cluster-resources
        namespaces:
          - {{ .Values.namespace }}

    - logs:
        name: router-logs
        namespace: {{ .Values.namespace }}
        selector:
          - {{ .Values.selector | default "app.kubernetes.io/name=router" }}
        {{- if or .Values.logs.maxAge .Values.logs.maxLines }}
        limits:
          {{- if .Values.logs.maxAge }}
          maxAge: {{ .Values.logs.maxAge }}
          {{- end }}
          {{- if .Values.logs.maxLines }}
          maxLines: {{ .Values.logs.maxLines }}
          {{- end }}
        {{- end }}

    # `mode: local` runs support-bundle on the invoking user's own machine, which can't
    # resolve the router's in-cluster Service DNS name, so it targets a `localhost`
    # port-forward instead.
    - http:
        name: router-metrics
        get:
          {{- if eq .Values.mode "local" }}
          url: http://localhost:9090/metrics
          {{- else }}
          url: http://{{ include "router-diagnostics.routerServiceName" . | default "<router-metrics-host-not-found>" }}.{{ .Values.namespace }}.svc.cluster.local:9090/metrics
          {{- end }}

    - configMap:
        collectorName: router-config-rendered
        namespace: {{ .Values.namespace }}
        {{- if .Values.configMapName }}
        name: {{ .Values.configMapName }}
        {{- else }}
        selector:
          - {{ .Values.selector | default "app.kubernetes.io/name=router" }}
        {{- end }}
        includeAllData: true

    - nodeMetrics:
        collectorName: router-resource-usage

    - data:
        name: meta.json
        data: |
          {
            "spec_version": "1",
            "mode": "{{ .Values.mode }}",
            "namespace": "{{ .Values.namespace }}",
            "min_troubleshoot_version": "0.120.0"
          }
{{- end -}}
