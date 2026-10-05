# router-diagnostics Job image

The container image the router support tool's `mode: job` runs bundling a pinned troubleshoot `support-bundle`
binary plus `aws-cli`/`gcloud`/`curl` for the object-storage upload paths.


## Local build and test

```bash
docker build --platform linux/arm64 -t router-diagnostics-job-image:dev router-diagnostics-job-image
```

Use `linux/amd64` instead if your `kind` nodes are x86.

```bash
kind load docker-image router-diagnostics-job-image:dev --name <your-cluster>

helm upgrade --install router-diagnostics router-diagnostics-chart \
  --namespace <namespace> \
  --set namespace=<namespace> \
  --set mode=job \
  --set job.image.repository=router-diagnostics-job-image \
  --set job.image.tag=dev \
  --set job.image.pullPolicy=IfNotPresent \
  --set job.storage.provider=url \
  --set job.storage.url.endpoint=<your-upload-endpoint>
```

`job.storage.provider` is required for `mode: job`. `url` is the simplest option for a local test loop since it needs no cloud credentials, just an HTTP(S) endpoint to receive the upload. Go to `specs/storage/object_storage.md` for details.
