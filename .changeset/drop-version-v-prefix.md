---
category: fix
breaking: true
---

Drop the leading `v` from every published version tag

`v1.0.0` shipped with a leading `v` on the chart's OCI tag, the Job image tag, and the
GitHub Release tag. That's not valid semver, and Helm's OCI client resolves an unpinned
`helm install oci://...` (no `--version` given) by parsing every tag as semver and
picking the highest one - a non-semver tag breaks that resolution for the *entire*
repository, not just that one tag. Confirmed directly: `helm install
oci://registry-1.docker.io/apollograph/router-diagnostics-chart` failed with "unable to
locate any tags" the moment any `vX.Y.Z`-tagged release existed, while
`apollographql/operator-chart` (whose tags are all bare semver) resolves an unpinned
install correctly.

`release_prepare.yaml` and `release_finalize.yaml` now compute and validate every
version as bare semver (`X.Y.Z`, no leading `v`) - the chart version, the Job image tag,
the git/release tag, and the changeset notes filename. `router-diagnostics-chart/values.yaml`'s
`job.image.tag` default is corrected from `"v1.0.0"` to `"1.0.0"` to match.

`v1.0.0`'s published artifacts (the Docker Hub image tag, the OCI chart tag, and the
GitHub Release) are being removed and re-published as plain `1.0.0` under this fix.
