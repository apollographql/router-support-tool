---
category: test
breaking: false
---

Add the router-resource-usage collector module and its unit tests

A standard-library Python module that lists the router's pods through the API server, reads
each node's kubelet once, and keeps only those pods. It names the reason for every file it
doesn't write. It isn't wired into the chart yet; its unit tests run in CI as
`mise run test-resource-usage`.
