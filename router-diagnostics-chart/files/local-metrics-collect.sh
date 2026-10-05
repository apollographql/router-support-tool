PODS=$(kubectl get pods -n "{{ .Values.namespace }}" -l "{{ .Values.selector | default "app.kubernetes.io/name=router" }}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for POD in $PODS; do
  kubectl port-forward -n "{{ .Values.namespace }}" "pod/$POD" "{{ .Values.metricsPort | default 9090 }}:{{ .Values.metricsPort | default 9090 }}" >/dev/null 2>&1 &
  PF_PID=$!
  for i in $(seq 1 30); do
    curl -sf "http://localhost:{{ .Values.metricsPort | default 9090 }}/metrics" -o "$TS_OUTPUT_DIR/${POD}.txt" 2>/dev/null && break
    sleep 0.5
  done
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
done
if [ -z "$(ls "$TS_OUTPUT_DIR"/*.txt 2>/dev/null)" ]; then
  echo "metrics not collected: no pod responded on port {{ .Values.metricsPort | default 9090 }} — prometheus may not be enabled"
fi
