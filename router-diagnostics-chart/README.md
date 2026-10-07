# router-diagnostics-chart

![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1](https://img.shields.io/badge/AppVersion-1-informational?style=flat-square)

On-demand troubleshoot.sh support-bundle collection for Apollo Router.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| configMapName | string | `""` | Raw-manifest / custom deployments only. Name of the ConfigMap holding the router's rendered config. Defaults to label-based discovery (via `selector`). Leave unset when the router was deployed via the official Apollo Helm chart. |
| job | object | `{"collectNodeMetrics":true,"image":{"pullPolicy":"IfNotPresent","repository":"apollograph/router-diagnostics","tag":"1.0.0"},"imagePullSecrets":[],"podAnnotations":{},"podLabels":{},"serviceAccount":{"annotations":{}},"storage":{"bucket":"","existingSecret":"","gcs":{"credentialsJson":"","project":""},"prefix":"","provider":"","s3":{"accessKeyId":"","endpoint":"","forcePathStyle":false,"region":"","secretAccessKey":""},"url":{"endpoint":"","headers":{},"method":"PUT"}},"ttlSecondsAfterFinished":3600}` | mode: job only |
| job.collectNodeMetrics | bool | `true` | Optional. Set false to skip creating the cluster-scoped ClusterRole/ClusterRoleBinding that grants the nodeMetrics collector its nodes/nodes-proxy/nodes-stats access and to decline that collector's data entirely up front. Prometheus is the preferred alternative. Defaults to true. |
| job.image.repository | string | `"apollograph/router-diagnostics"` | The image bundling the support-bundle binary Apollo publishes, tagged to match this chart's own release version. The troubleshoot.sh version it bundles is a separate, independently-pinned detail — see a collected bundle's meta.json find out which one. Override only to pin an older release or point at a private mirror. |
| job.imagePullSecrets | list | `[]` | Optional. Names of existing image pull secrets to attach to the Job's pod, in the standard Kubernetes `imagePullSecrets` shape (e.g. `[{name: my-registry-secret}]`). Only needed if you've overridden `job.image.repository` to point at a private mirror. |
| job.podAnnotations | object | `{}` | Annotations merged onto the Job's pod template. Customer-supplied keys win over the defaults below (sidecar.istio.io/inject: "false", linkerd.io/inject: disabled) rather than replacing them wholesale. |
| job.podLabels | object | `{}` | Arbitrary labels merged onto the Job's pod template. |
| job.serviceAccount.annotations | object | `{}` | Merged onto the Job's ServiceAccount. Carries `eks.amazonaws.com/role-arn` for IRSA or `iam.gke.io/gcp-service-account` for Workload Identity, whichever matches `job.storage.provider` — the recommended credential path for `job.storage`, needing no Secret. See specs/storage/object_storage.md -> Credentials. |
| job.storage.bucket | string | `""` | Required for `provider: s3`/`gcs`. Destination bucket for the uploaded bundle. |
| job.storage.existingSecret | string | `""` | Optional. Name of a Secret the customer creates themselves. For `provider: s3`, holds `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` keys; for `provider: gcs`, a GCP service-account JSON key; for `provider: url`, arbitrary keys, each becoming a header on the upload request (key = header name, value = header value). Mutually exclusive with the static `s3`/`gcs` credential values above — set at most one credential path. Not mutually exclusive with `url.headers` for `provider: url`; see specs/storage/object_storage.md -> Credentials. |
| job.storage.gcs.credentialsJson | string | `""` | Optional, not recommended. A GCP service-account JSON key, templated directly into the Job's container as a mounted file — visible in `helm get values` and git history if committed. Prefer `existingSecret` or Workload Identity (`job.serviceAccount.annotations`) instead. Set this via `-f values.yaml` or `--set-json`, never plain `--set` — Helm's `--set` parses commas and braces as its own list/map syntax and will silently mangle the JSON. |
| job.storage.gcs.project | string | `""` | Optional for `provider: gcs`. The GCP project `gcloud` bills API calls to. |
| job.storage.prefix | string | `""` | Optional, `provider: s3`/`gcs` only. Key prefix within the bucket, e.g. `router-bundles/`. |
| job.storage.provider | string | `""` | Required for `mode: job`. `s3` (AWS S3 or an S3-compatible store, e.g. MinIO/Ceph RGW, via `job.storage.s3`), `gcs`, or `url` (a plain HTTP(S) PUT/POST to an endpoint you control). |
| job.storage.s3.accessKeyId | string | `""` | Optional, not recommended. Static credential, templated directly into the Job's container — visible in `helm get values` and git history if committed. Prefer `existingSecret` or IRSA (`job.serviceAccount.annotations`) instead. |
| job.storage.s3.endpoint | string | `""` | Optional. Override for a non-AWS S3-compatible store (MinIO, Ceph RGW, etc). |
| job.storage.s3.forcePathStyle | bool | `false` | Optional. Most on-prem S3-compatible stores need this set true. |
| job.storage.s3.region | string | `""` | Required for `provider: s3` unless using an S3-compatible store where the region is implied by `endpoint`. |
| job.storage.s3.secretAccessKey | string | `""` | Optional, not recommended. See `accessKeyId` above for why. |
| job.storage.url.endpoint | string | `""` | Required for `provider: url`. The bare HTTP(S) endpoint the bundle is uploaded to. |
| job.storage.url.headers | object | `{}` | Optional for `provider: url`. Static headers templated directly into the upload request — visible in `helm get values` and git history if committed. Sent alongside (not instead of) any headers sourced from `existingSecret` below. See specs/storage/object_storage.md -> Credentials. |
| job.storage.url.method | string | `"PUT"` | Optional for `provider: url`. `PUT` or `POST`. |
| job.ttlSecondsAfterFinished | int | `3600` | Seconds after the Job finishes before Kubernetes garbage-collects it (and its pod). Keeps the cluster from accumulating a completed Job/pod per collection. |
| logs.maxAge | string | `""` | Optional. Maps to the `logs` collector's `limits.maxAge`, e.g. `2h`. Left unset, collection is uncapped by age. |
| logs.maxLines | string | `""` | Optional. Maps to `limits.maxLines`. Left unset, troubleshoot.sh's own default (10000) applies — this chart does not re-declare that default. |
| metricsPort | string | `""` | Optional. Port the router's metrics endpoint listens on. Defaults to `9090`. Only set this if your exporter uses a different port. |
| mode | string | `""` | Required. `local` or `job`. |
| namespace | string | `""` | Required. The router's namespace. Rendered into every collector that accepts a namespace, including `clusterResources.namespaces` as a single-element list. Never rely on the invoking kubectl context's default namespace. |
| selector | string | `""` | Raw-manifest / custom deployments only. Pod label selector for the router, e.g. `app=my-router`. Defaults to the official chart's own `app.kubernetes.io/name=router` label — leave unset when the router was deployed via the official Apollo Helm chart. Under `mode: job`, setting this is also what enables metrics collection for this tier — see `metricsPort` below. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
