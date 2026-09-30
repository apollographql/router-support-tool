# Published image for router-diagnostics's `mode: job`
ARG GCLOUD_VERSION=584.0.0

FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:${GCLOUD_VERSION}-alpine AS gcloud-sdk

FROM alpine:3.22

# Renovate's apk datasource only detects a version written directly
# on the apk add line and skips one supplied through a variable.
RUN apk add --no-cache \
    ca-certificates=20260909-r0 \
    aws-cli=2.27.25-r0 \
    curl=8.14.1-r3

COPY --from=gcloud-sdk /google-cloud-sdk /google-cloud-sdk
ENV PATH="/google-cloud-sdk/bin:$PATH"
# Prevent gcloud from trying to write logs back into the (read-only) container filesystem.
ENV CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true

ARG SUPPORT_BUNDLE_VERSION="0.134.1"
ARG TARGETARCH
ADD https://github.com/replicatedhq/troubleshoot/releases/download/v${SUPPORT_BUNDLE_VERSION}/support-bundle_linux_${TARGETARCH}.tar.gz /tmp/sb.tar.gz
RUN tar xzf /tmp/sb.tar.gz -C /usr/local/bin support-bundle && \
    chmod +x /usr/local/bin/support-bundle && \
    rm /tmp/sb.tar.gz

# The Job template (router-diagnostics/templates/job.yaml) always overrides this with its own
# collect-and-upload command. This ENTRYPOINT only matters for running the image directly.
ENTRYPOINT ["support-bundle"]
