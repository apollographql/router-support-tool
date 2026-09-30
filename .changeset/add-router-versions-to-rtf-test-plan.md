---
category: test
breaking: false
---

Adds other GraphOS Router versions to test with in the RTF test plan and uses a version-appropriate
router config for the RTF router_version matrix.

`redaction-testing-router-config.yaml` exhaustively exercises every redaction rule, but its schema
isn't stable across the full router_version range now tested. For example, `headers.all.request`'s shape changed.

Full redaction coverage stays pinned to `v2.17.0`. Every other tested version now uses a
new schema-stable config, `base-router-config.yaml`.
