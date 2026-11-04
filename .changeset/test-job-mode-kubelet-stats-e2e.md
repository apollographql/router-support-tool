---
category: test
breaking: false
---

Add a chainsaw test that runs a real job-mode collection and asserts on its kubelet stats

The new `job-mode-kubelet-stats` test builds the Job image from the checkout, installs a router and
a mock upload backend, runs the chart with `mode: job`, and checks the uploaded bundle: the
documented memory and CPU signals are present for the router container, only the router's pods are
in the stats file, a healthy run writes no named reasons, the diagnostic sidecar is redacted, and
neither a ServiceAccount token nor `APOLLO_KEY` appears. It runs in the kind integration workflow.
