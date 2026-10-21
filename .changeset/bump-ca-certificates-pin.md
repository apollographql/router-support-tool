---
category: fix
breaking: false
---

Fix the Job image build failing on the stale ca-certificates pin

Alpine 3.24 replaced `ca-certificates` `20260909-r0` with `20261020-r0` and no longer
serves the old version, so `apk add` in the Job image's Dockerfile failed with
`breaks: world[ca-certificates=20260909-r0]` and the image could not be built. The pin
is bumped to `20261020-r0`.

To keep this from recurring, Renovate now proposes the Job image's apk pins (the
repology-sourced `aws-cli`, `curl` and `ca-certificates` versions) with no release-age
wait, and groups them into one PR. Alpine drops a package's previous version as soon as
a new one lands, so a delayed bump leaves the exact pin unresolvable, and separate PRs
for packages Alpine updates together would each fail the image build on the other
packages' stale pins.
