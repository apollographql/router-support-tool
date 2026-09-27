---
category: test
breaking: false
---

Verify collect.sh caches the pinned troubleshoot version on real install

Adds an assertion to the official-chart chainsaw integration test: after collect.sh runs, the pinned
support-bundle binary must land at ~/.router-diagnostics/bin/support-bundle-v<version>.
