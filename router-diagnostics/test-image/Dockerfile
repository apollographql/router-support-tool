# NOT THE PRODUCTION IMAGE. This is a local dev/test image only, built to verify
# RR-1077's Job/RBAC templates against a real cluster -- it is never published
# anywhere.
#
# No kubectl: confirmed against the real support-bundle v0.134.0 binary's own --help
# output that it uses its own embedded Kubernetes client (kubeconfig/
# certificate-authority/client-certificate flags), not a shelled-out kubectl.
FROM alpine:3.20

RUN apk add --no-cache ca-certificates

ARG SUPPORT_BUNDLE_VERSION=v0.134.0
ARG TARGETARCH
ADD https://github.com/replicatedhq/troubleshoot/releases/download/${SUPPORT_BUNDLE_VERSION}/support-bundle_linux_${TARGETARCH}.tar.gz /tmp/sb.tar.gz
RUN tar xzf /tmp/sb.tar.gz -C /usr/local/bin support-bundle && \
    chmod +x /usr/local/bin/support-bundle && \
    rm /tmp/sb.tar.gz

ENTRYPOINT ["support-bundle"]
