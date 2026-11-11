---
category: feat
breaking: false
---

Add the router-resource-usage collector script and its unit tests

Adds a standard-library Python script that lists the router's pods through the API server, reads
each node's kubelet once, and keeps only those pods. It names the reason for every file it
doesn't write. Its unit tests run in CI via `mise` by running `mise run test-resource-usage`.
