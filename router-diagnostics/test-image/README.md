# Test image

This is a minimal base image for exercising `mode: job` locally. [RR-1145](https://apollographql.atlassian.net/browse/RR-1145) owns the real registry, versioning policy, and `aws-cli`/`gcloud` bundling. This one exists only to verify [RR-1077](https://apollographql.atlassian.net/browse/RR-1077)'s Job/RBAC templates against a real cluster and to carry some forward some of what e have learned thus far.

For the RTF verification plan (`testing/`), this image is also pushed to
`us-central1-docker.pkg.dev/platform-cross-environment/apollo-private-docker/router-support-tool/router-diagnostics-test:v0.134.0`
so the Orchestrator can pull it - that's a stand-in location, not the RR-1145 decision, since
pushing there requires write access to that path specifically (a plain `docker push` after
`gcloud auth configure-docker us-central1-docker.pkg.dev` is all it takes if you have it).

## Build and load into a local `kind` cluster

```bash
docker build --platform linux/arm64 -t router-diagnostics-test:v0.134.0 router-diagnostics/test-image
```

```bash
kind load docker-image router-diagnostics-test:v0.134.0 --name <your-cluster>
```

Use `linux/amd64` instead if your `kind` nodes are x86.

## Point the chart at it

```bash
helm upgrade --install router-diagnostics router-diagnostics \
  --namespace <namespace> \
  --set namespace=<namespace> \
  --set mode=job \
  --set job.image.repository=router-diagnostics-test \
  --set job.image.tag=v0.134.0 \
  --set job.image.pullPolicy=IfNotPresent
```

## Retrieving the bundle for inspection

There's no upload path yet (that's RR-1076). To actually inspect what a Job collected, run a throwaway pod with the same ServiceAccount and image, holding it open after collection:

```bash
kubectl run rbac-debug-check -n <namespace> --restart=Never \
  --overrides='{"spec":{"serviceAccountName":"router-diagnostics-job"}}' \
  --image=router-diagnostics-test:v0.134.0 \
  --command -- /bin/sh -c "support-bundle --load-cluster-specs; sleep 300"

kubectl wait --for=condition=Ready pod/rbac-debug-check -n <namespace> --timeout=60s

kubectl cp <namespace>/rbac-debug-check:$(kubectl exec -n <namespace> rbac-debug-check -- sh -c 'ls *.tar.gz') ./bundle.tar.gz

kubectl delete pod rbac-debug-check -n <namespace>
```
