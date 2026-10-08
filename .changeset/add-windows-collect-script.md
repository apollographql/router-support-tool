---
category: feat
breaking: false
---

Add collect.ps1 for Windows support in mode: local

Windows customers can now run `.\collect.ps1 -Namespace <namespace>` in PowerShell.
The script downloads and caches the same pinned `support-bundle.exe` binary 
(keyed by version, from the `windows_amd64` release asset), checks for `kubectl` on PATH,
and runs `support-bundle` with the same flags as the shell script.
