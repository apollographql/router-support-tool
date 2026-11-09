---
category: test
breaking: false
---

Check in RTF that missing kubelet stats come with a stated reason

The job-mode kubelet stats collector must say why it collected nothing. RTF now checks two cases:

- No pod matches the selector.
- Collection is declined at install, in a new `kubelet-declined` condition that installs the chart
  with `job.collectNodeMetrics: false`.
