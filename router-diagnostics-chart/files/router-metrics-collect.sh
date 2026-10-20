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

# No port-forward, so a pod's "no response" line has nothing to add.
scrape_error() { :; }
{{- else }}

# Pod IPs aren't reachable from the user's machine, so forward each pod's port in turn.
# The forward's output is kept so a pod that didn't respond can show why the forward failed.
# Without a temp dir it goes to /dev/null: scraping still works, just without the reason.
if PF_DIR=$(mktemp -d 2>/dev/null); then
  trap 'rm -rf "$PF_DIR"' EXIT
  PF_OUT="$PF_DIR/out"
  PF_ERR="$PF_DIR/err"
else
  PF_OUT=/dev/null
  PF_ERR=/dev/null
fi
scrape() {
  kubectl port-forward -n "$NAMESPACE" "pod/$1" "$PORT:$PORT" >"$PF_OUT" 2>"$PF_ERR" &
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

# kubectl port-forward's own error for the last pod, joined onto one line, only when the
# forward itself failed. Once kubectl prints "Forwarding from" the forward was up, and any
# later error (connection refused, lost connection) just means nothing answered on the port.
scrape_error() {
  [ -s "$PF_ERR" ] || return 0
  grep -q '^Forwarding from' "$PF_OUT" && return 0
  ERR=$(tr '\n' ' ' < "$PF_ERR" | sed 's/ *$//')
  if [ -n "$ERR" ]; then
    printf ' — kubectl port-forward: %s' "$ERR"
  fi
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
    echo "metrics not collected for pod $POD: no response on port $PORT$(scrape_error)"
  fi
done <<EOF
$PODS
EOF
if [ -z "$(ls "$TS_OUTPUT_DIR"/*.txt 2>/dev/null)" ]; then
  echo "metrics not collected: no pod responded on port $PORT — prometheus may not be enabled"
fi
