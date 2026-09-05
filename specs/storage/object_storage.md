# Customer-provided object storage

This spec describes the mechanism for pushing the resulting `support-bundle-<timestamp>.tar.gz` to an object storage bucket the customer already owns and configures via our support tool's `values.yaml`. Retention is the bucket's problem, we do not build or operate a retention mechanism.

Supported targets:

- AWS S3
- Google Cloud Storage (GCS)

Object storage only applies to `mode: job` (see below), so its values nest under `job:` rather than sitting at the top level, alongside whatever other `job.*` values a given version's chart already defines (pod annotations/labels, etc.):

```yaml
job:
  storage:
    provider: s3        # s3 | gcs
    bucket: my-router-diagnostics
    prefix: router-bundles/
    # AWS-specific
    s3:
      region: us-east-1
    # GCS-specific
    gcs:
      project: my-gcp-project
```

When a customer runs the tool with `mode: job`, a Kubernetes Job is created to run the collection unattended, in-cluster, using a namespace-scoped ServiceAccount the chart creates for it. When `job.storage` is configured, a step in the Job's container uploads the bundle to the configured bucket immediately after collection completes, using credentials scoped to that same ServiceAccount rather than a static key baked into the chart, see [ServiceAccount credentials](#serviceaccount-credentials).

Note: `mode: local` does not use this. The bundle already lands as a plain file in the current directory of whoever ran `kubectl support-bundle --load-cluster-specs`.

## ServiceAccount credentials

Uploading from inside the Job needs IRSA (AWS) or Workload Identity (GCP) bound to the Job's ServiceAccount. Both are configured by annotating that ServiceAccount, so object storage needs one more chart value.

| Value | Required | Default | Applies to | Purpose |
| --- | --- | --- | --- | --- |
| `job.serviceAccount.annotations` | Yes, if `job.storage` is set | `{}` | `mode: job` | Merged onto the Job's ServiceAccount. Carries `eks.amazonaws.com/role-arn` for IRSA or `iam.gke.io/gcp-service-account` for Workload Identity — whichever matches `job.storage.provider`. |

This value is additive to the chart. It's an annotation on the ServiceAccount, not a Role or RoleBinding rule and since the upload is a call to a cloud object storage API, not to the Kubernetes API server, it needs no new Kubernetes RBAC.

## Cloud IAM for storage

Object storage needs authorization on the cloud provider's side, bound to the Job's ServiceAccount via IRSA/Workload Identity:

- **S3** — an IAM role, trusted for the Job's ServiceAccount (namespace + name) via the cluster's OIDC provider, granting at minimum `s3:PutObject` scoped to `arn:aws:s3:::<bucket>/<prefix>*`.
- **GCS** — a GCP service account, bound to the Job's ServiceAccount via `roles/iam.workloadIdentityUser`, granting at minimum `storage.objects.create` on the bucket (the predefined `roles/storage.objectCreator` role covers this).

Neither needs read, list, or delete on the bucket — the Job only ever writes one object per run.

The customer sets up the IAM role or GCP service account itself, outside this tool, the same way the bucket itself is outside this tool. The chart's only job is to merge the resulting annotation onto the ServiceAccount it already creates.
