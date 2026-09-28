---
category: test
breaking: false
---

Add router-recently-restarted RTF test case

Covers the "Router recently restarted" scenario from the verification plan: restarts one router
pod's container in place (not a full pod replacement, which would leave no restart history to
find) and asserts the logs collector's previous-container capture actually produced a real
startup sequence in both the previous and current container logs.
