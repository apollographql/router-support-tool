# NOT THE PRODUCTION IMAGE. This is a local dev/test image only, built to verify
# the Job/RBAC templates and upload step against a real cluster --
# it is never published anywhere.
#
# No kubectl: confirmed against the real support-bundle v0.134.0 binary's own --help
# output that it uses its own embedded Kubernetes client (kubeconfig/
# certificate-authority/client-certificate flags), not a shelled-out kubectl.
#
# aws-cli is included (via Alpine's own package, not AWS's installer) to test the
# S3 upload path against a real MinIO instance. gcloud is not included: it has no Alpine
# package. The gcs path is verified by template rendering only, until RR-1145's production image exists.
FROM alpine:3.20

RUN apk add --no-cache ca-certificates aws-cli

ARG SUPPORT_BUNDLE_VERSION=v0.134.0
ARG TARGETARCH
ADD https://github.com/replicatedhq/troubleshoot/releases/download/${SUPPORT_BUNDLE_VERSION}/support-bundle_linux_${TARGETARCH}.tar.gz /tmp/sb.tar.gz
RUN tar xzf /tmp/sb.tar.gz -C /usr/local/bin support-bundle && \
    chmod +x /usr/local/bin/support-bundle && \
    rm /tmp/sb.tar.gz

ENTRYPOINT ["support-bundle"]
