NAMESPACE={{ .Values.namespace | squote }}
SELECTOR={{ .Values.selector | default "app.kubernetes.io/name=router" | squote }}
PORT={{ .Values.metricsPort | default 9090 | toString | squote }}
{{- if eq .Values.mode "job" }}

# ignoreParentEnvs drops the KUBERNETES_SERVICE_HOST/PORT variables kubectl uses to find
# the API server from inside a pod, so point it there explicitly with the Job's own
# ServiceAccount credentials.
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
kubectl() {
  command kubectl --server=https://kubernetes.default.svc \
    --certificate-authority="$SA_DIR/ca.crt" --token="$(cat "$SA_DIR/token")" "$@"
}

# The Job's pod is inside the cluster network, so each pod IP is reachable directly.
scrape() {
  curl -sf --connect-timeout 5 --max-time 30 "http://$2:$PORT/metrics" -o "$TS_OUTPUT_DIR/$1.txt"
}
{{- else }}

# Pod IPs aren't reachable from the user's machine, so forward each pod's port in turn.
scrape() {
  kubectl port-forward -n "$NAMESPACE" "pod/$1" "$PORT:$PORT" >/dev/null 2>&1 &
  PF_PID=$!
  SCRAPED=1
  for i in $(seq 1 30); do
    curl -sf "http://localhost:$PORT/metrics" -o "$TS_OUTPUT_DIR/$1.txt" 2>/dev/null && { SCRAPED=0; break; }
    sleep 0.5
  done
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  return "$SCRAPED"
}
{{- end }}

# kubectl's own error goes to stderr, which troubleshoot.sh saves next to this output.
if ! PODS=$(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}'); then
  echo "metrics not collected: could not list pods matching selector $SELECTOR in namespace $NAMESPACE"
  exit 0
fi
if [ -z "$PODS" ]; then
  echo "metrics not collected: no pods matched selector $SELECTOR in namespace $NAMESPACE"
  exit 0
fi
while read -r POD POD_IP; do
  if ! scrape "$POD" "$POD_IP"; then
    rm -f "$TS_OUTPUT_DIR/$POD.txt"
    echo "metrics not collected for pod $POD: no response on port $PORT"
  fi
done <<EOF
$PODS
EOF
if [ -z "$(ls "$TS_OUTPUT_DIR"/*.txt 2>/dev/null)" ]; then
  echo "metrics not collected: no pod responded on port $PORT — prometheus may not be enabled"
fi
