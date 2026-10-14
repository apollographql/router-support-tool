---
category: fix
breaking: false
---

Fix `mode: job` GCS uploads failing with "no active account selected"

`job.storage.provider=gcs` with a key-file-based credential (`existingSecret` or a
static `credentialsJson`) always failed the upload step with `ERROR:
(gcloud.storage.cp) You do not currently have an active account selected.`
`GOOGLE_APPLICATION_CREDENTIALS` satisfies Application Default Credentials for client
libraries, but the `gcloud` CLI binary itself still needs an explicitly activated
account - nothing in `collect-and-upload.sh` ever did that. Confirmed against a real
GCS bucket: collection always succeeded, but the upload never did.

`collect-and-upload.sh`'s `gcs` branch now runs `gcloud auth activate-service-account
--key-file="$GOOGLE_APPLICATION_CREDENTIALS"` before the upload, only when that env var
is set.
