# Customer-provided object storage

This spec describes the mechanism for pushing the resulting `support-bundle-<timestamp>.tar.gz` to an object storage bucket the customer already owns and configures via our support tool's `values.yaml`. Retention is the bucket's problem, we do not build or operate a retention mechanism.

Supported targets:

- AWS S3 and S3-compatible stores via `job.storage.s3.endpoint`
- Google Cloud Storage (GCS)
- A bare HTTP(S) endpoint (`provider: url`) — for a customer whose destination isn't S3 or GCS at all (an internal upload API, a signed-URL receiver, etc.), or for standing up a lightweight receiver in a test environment without a real cloud bucket.

Object storage only applies to `mode: job` (see below), so its values nest under `job:` rather than sitting at the top level, alongside whatever other `job.*` values a given version's chart already defines (pod annotations/labels, etc.):

```yaml
job:
  storage:
    provider: s3        # s3 | gcs | url
    bucket: my-router-diagnostics
    prefix: router-bundles/
    # AWS-specific and any S3-compatible store (MinIO, Ceph RGW, etc.)
    s3:
      region: us-east-1
      endpoint: ""            # override for a non-AWS S3-compatible endpoint
      forcePathStyle: false   # most on-prem S3-compatible stores need this set true
    # GCS-specific
    gcs:
      project: my-gcp-project
    # url-specific
    url:
      endpoint: https://example.com/upload/support-bundle
      method: PUT       # PUT | POST, defaults to PUT
      headers: {}       # static headers, e.g. Authorization: "Basic <base64>" -- see Credentials below
    # optional; see Credentials below. Omit to use the Job's ServiceAccount (IRSA/Workload Identity).
    # Not applicable to provider: url; see Credentials below for how that provider sources headers instead.
    existingSecret: ""
```

When a customer runs the tool with `mode: job`, a Kubernetes Job is created to run the collection unattended, in-cluster, using a namespace-scoped ServiceAccount the chart creates for it. When `job.storage` is configured, the Job's container uploads the bundle to the configured destination immediately after collection completes. For `provider: s3`/`gcs` this means invoking the provider's own CLI (`aws s3 cp` / `gcloud storage cp`, both already present in the image alongside the pinned troubleshoot.sh binary) rather than a bespoke uploader we write ourselves; that CLI resolves credentials through its own standard chain, which is what lets this spec support more than one credential strategy for those two providers — see [Credentials](#credentials). For `provider: url`, the Job does a plain `curl -X <method> -T <bundle> <headers...> "<endpoint>"` — there's no cloud CLI to defer to, so the chart builds the request directly.

Note: `mode: local` does not use this. The bundle already lands as a plain file in the current directory of whoever ran `kubectl support-bundle --load-cluster-specs`.

## `job.storage.provider` is required for `mode: job`

Because there is no way to get the bundle out otherwise, the chart fails the install at render time (`fail` in `templates/job.yaml`) when `mode: job` and `job.storage.provider` is unset, rather than silently producing a bundle nobody can retrieve.

## Credentials

Because the upload goes through the provider's own CLI, any credential source that the CLI already knows how to resolve works here. The following are supported:

- **IRSA (AWS) / Workload Identity (GCP) — recommended.** No secrets to store or rotate. Requires annotating the Job's ServiceAccount:

  | Value | Required | Default | Applies to | Purpose |
  | --- | --- | --- | --- | --- |
  | `job.serviceAccount.annotations` | Yes, if using this path | `{}` | `mode: job` | Merged onto the Job's ServiceAccount. Carries `eks.amazonaws.com/role-arn` for IRSA or `iam.gke.io/gcp-service-account` for Workload Identity — whichever matches `job.storage.provider`. |

  This value is additive to the chart. It's an annotation on the ServiceAccount, not a Role or RoleBinding rule — the upload is a call to a cloud object storage API, not to the Kubernetes API server, so it needs no new Kubernetes RBAC. See [Cloud IAM for storage](#cloud-iam-for-storage) for what to grant.

- **Static credentials via a Secret — for clusters without IRSA/Workload Identity available:** such as on-prem, or an S3-compatible store like MinIO/Ceph that has no equivalent federation mechanism. Set `job.storage.existingSecret` to the name of a Secret the customer creates themselves, with keys named `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for `provider: s3` or a GCP service-account JSON key for `provider: gcs`. The chart mounts it into the Job's container as env vars/a file, and the CLI picks it up the same way it would on a developer's own machine. We never see or template the credential values themselves. When `existingSecret` is set, `job.serviceAccount.annotations` isn't needed.

- **Static credentials via values — not recommended.** For a customer with no secrets-management story who wants to get running quickly: `job.storage.s3.accessKeyId`/`secretAccessKey` for `provider: s3`, or `job.storage.gcs.credentialsJson` for `provider: gcs`, set directly as chart values. The chart templates these into the same env vars/file the Secret path above would mount, so nothing else about the upload changes. **The credential will be exposed** in shell history, `helm get values`, and git history if committed. Prefer `existingSecret` or IRSA/Workload Identity above whenever the customer has any way to manage a Secret directly.

`provider: url` doesn't fit the above three paths — there's no cloud IAM identity for a bare endpoint, so IRSA/Workload Identity doesn't apply, and whatever the endpoint needs (a bearer token, a signed-URL query param baked into a header, basic auth) is just an HTTP header. Two ways to supply headers, combinable:

- **Via `job.storage.existingSecret`** — a Secret the customer creates themselves, containing zero or more arbitrary keys. Each key becomes a header name on the upload request; that key's value becomes the header's value. The chart mounts the Secret as a volume (not env vars, since header names aren't fixed the way `AWS_ACCESS_KEY_ID` is) and the script turns each file in the mount into a `-H "<name>: <value>"`. We never see or template the values themselves.
- **Directly via `job.storage.url.headers`** — a map of header name to value, templated straight into the request. Same exposure caveat as the static-values path above: visible in `helm get values` and git history if committed.

Headers from both sources are sent together when both are set (`existingSecret` first, then `url.headers`); if the same header name appears in both, the request carries it twice; note that `curl` sends all `-H` occurrences it's given.

## Cloud IAM for storage

Whichever credential path is used, the minimum permissions are the same:

- **S3** — `s3:PutObject` scoped to `arn:aws:s3:::<bucket>/<prefix>*` (or the equivalent bucket policy for an S3-compatible store without IAM ARNs).
- **GCS** — `storage.objects.create` on the bucket (the predefined `roles/storage.objectCreator` role covers this).

Neither needs read, list, or delete on the bucket — the Job only ever writes one object per run.

This section doesn't apply to `provider: url` — there's no cloud IAM involved, auth there is whatever the receiving endpoint enforces via the headers described above.

The customer sets this up themselves, outside this tool, the same way the bucket itself is outside this tool.

Note: This doesn't apply to `provider: url`, auth there is whatever the receiving endpoint enforces.
