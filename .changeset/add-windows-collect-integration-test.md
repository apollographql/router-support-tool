---
category: test
breaking: false
---

Add kind-based integration test for collect.ps1 on Windows

A new GitHub Actions job (`exercise_local_collect_windows`) runs `collect.ps1`
against a real kind cluster on `windows-latest`, verifying that Windows collection
actually produces a support bundle end to end.
