---
category: ci
breaking: false
---

Harden the Job's container image

Pinned aws-cli, curl, and ca-certificates to explicit apk versions and added a
Wiz vulnerability scan that fails the build on a CRITICAL finding without an
accepted exception. Renovate now tracks the pinned apk versions directly via a
`packageRules` entry in `.github/renovate.json5`.
