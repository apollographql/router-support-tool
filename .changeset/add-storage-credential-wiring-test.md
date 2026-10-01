---
category: test
breaking: false
---

Adds template checks for job.storage credential wiring

Adds new mise task, `test-storage-credentials` that asserts job.storage's existingSecret and
static-value credential paths render correctly for both S3 and GCS and wired these updates
into lefthook and CI.
