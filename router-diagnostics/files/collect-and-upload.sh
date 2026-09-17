set -eu
support-bundle --load-cluster-specs
PROVIDER="${1:-}"
if [ -n "$PROVIDER" ]; then
  BUNDLE=$(ls -t support-bundle-*.tar.gz | head -n1)
  case "$PROVIDER" in
    s3)
      BUCKET="$2"
      PREFIX="$3"
      REGION="$4"
      ENDPOINT="$5"
      FORCE_PATH_STYLE="$6"
      if [ "$FORCE_PATH_STYLE" = "true" ]; then
        mkdir -p /tmp/.aws-config
        printf '[default]\ns3 =\n    addressing_style = path\n' > /tmp/.aws-config/config
        export AWS_CONFIG_FILE=/tmp/.aws-config/config
      fi
      set -- aws s3 cp "$BUNDLE" "s3://$BUCKET/$PREFIX$BUNDLE"
      [ -n "$REGION" ] && set -- "$@" --region "$REGION"
      [ -n "$ENDPOINT" ] && set -- "$@" --endpoint-url "$ENDPOINT"
      "$@"
      ;;
    gcs)
      BUCKET="$2"
      PREFIX="$3"
      PROJECT="$4"
      set -- gcloud storage cp "$BUNDLE" "gs://$BUCKET/$PREFIX$BUNDLE"
      [ -n "$PROJECT" ] && set -- "$@" --project="$PROJECT"
      "$@"
      ;;
    url)
      ENDPOINT="$2"
      METHOD="$3"
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
      curl -sSf -X "$METHOD" -T "$BUNDLE" "$@" "$ENDPOINT"
      ;;
  esac
fi
