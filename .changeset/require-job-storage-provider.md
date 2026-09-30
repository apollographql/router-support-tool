---
category: fix
breaking: true
---

Require job.storage.provider for mode: job

Leaving `job.storage.provider` unset for `mode: job` previously rendered a Job that wrote the
bundle inside its own container with no way to get it back out. The chart now fails the install
at render time when `mode: job` and `job.storage.provider` is unset, rather than silently
producing a bundle that cannot be retrieved. Existing installs that rely on `mode: job` without
`job.storage` configured must set `job.storage.provider` to `s3`, `gcs`, or `url` before
upgrading.
