---
category: test
breaking: false
---

Add Windows CI logic test for collect.ps1 (mocked support-bundle)

A new GitHub Actions job (`exercise_local_collect_windows`) runs `collect.ps1`
on `windows-latest`, exercising its argument parsing, cache management, binary
invocation, and exit-code passthrough. `collect.ps1` gains a
`SUPPORT_BUNDLE_BIN_OVERRIDE` env var: when set, it replaces the computed
versioned `.exe` path so tests can point `& $Bin` at a PowerShell stub instead.
`testing/mock-troubleshoot.ps1` stands in for the real binary: it uses `tar` to
write a `.tar.gz` with the expected `cluster-resources/` and `router-logs/`
directory structure, which the job asserts.
