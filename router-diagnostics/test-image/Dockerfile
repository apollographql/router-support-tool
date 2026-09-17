# NOT THE PRODUCTION IMAGE. This is a local dev/test image only, built to verify
# the Job/RBAC templates and upload step against a real cluster --
# it is never published anywhere.
#
# No kubectl: confirmed against the real support-bundle v0.134.0 binary's own --help
# output that it uses its own embedded Kubernetes client (kubeconfig/
# certificate-authority/client-certificate flags), not a shelled-out kubectl.
#
# aws-cli is included (via Alpine's own package, not AWS's installer) to test the
# S3 upload path against a real MinIO instance. 
# curl is included to test the provider: url upload path.
# gcloud is lifted from Google's image
ARG GCLOUD_VERSION=584.0.0

FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:${GCLOUD_VERSION}-alpine AS gcloud-sdk

FROM alpine:3.20

RUN apk add --no-cache ca-certificates aws-cli curl

COPY --from=gcloud-sdk /google-cloud-sdk /google-cloud-sdk
ENV PATH="/google-cloud-sdk/bin:$PATH"
# Prevent gcloud from trying to write logs back into the (read-only) container filesystem.
ENV CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true

ARG SUPPORT_BUNDLE_VERSION=v0.134.0
ARG TARGETARCH
ADD https://github.com/replicatedhq/troubleshoot/releases/download/${SUPPORT_BUNDLE_VERSION}/support-bundle_linux_${TARGETARCH}.tar.gz /tmp/sb.tar.gz
RUN tar xzf /tmp/sb.tar.gz -C /usr/local/bin support-bundle && \
    chmod +x /usr/local/bin/support-bundle && \
    rm /tmp/sb.tar.gz

ENTRYPOINT ["support-bundle"]
