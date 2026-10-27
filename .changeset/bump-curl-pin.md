---
category: fix
breaking: false
---

Fix the Job image build failing on the stale curl pin

Alpine 3.24 replaced `curl` `8.22.0-r0` with `8.23.0-r0` and no longer serves the old
version, so `apk add` in the Job image's Dockerfile fails with
`breaks: world[curl=8.22.0-r0]` on any build that misses the Docker layer cache. The pin
is bumped to `8.23.0-r0`.
