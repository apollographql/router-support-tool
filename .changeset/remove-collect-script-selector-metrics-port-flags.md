---
category: fix
breaking: true
---

Remove `collect.sh`'s unused `--selector`/`--metrics-port` flags

These flags were parsed but not used. `collect.sh` now takes only `--namespace`.
