---
category: docs
breaking: false
---

Document the kubelet stats collection in mode: job

Under `mode: job`, container memory and CPU now come from the kubelet and need only `nodes/stats`
and `nodes`, not `nodes/proxy`. The docs describe the two grants, where the stats land in the
bundle, and the lines that say why stats are missing. The `mode: local` page now covers the
grants that mode needs.
