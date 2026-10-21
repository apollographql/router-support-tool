---
category: fix
breaking: false
---

Fix the Job image build failing on the stale ca-certificates pin

Alpine 3.24 replaced `ca-certificates` `20260909-r0` with `20261020-r0` and no longer
serves the old version, so `apk add` in the Job image's Dockerfile failed with
`breaks: world[ca-certificates=20260909-r0]` and the image could not be built. The pin
is bumped to `20261020-r0`.
