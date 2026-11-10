---
category: test
breaking: false
---

Check in RTF that missing kubelet stats come with a stated reason

The job-mode kubelet stats collector must say why it collected nothing. RTF now checks three cases:

- No pod matches the selector.
- Collection is declined at install, in a new `kubelet-declined` condition that installs the chart
  with `job.collectNodeMetrics: false`.
- The kubelet refuses the Job's token because its ServiceAccount lacks `nodes/stats`, in one variant
  (`healthy` on the newest Router 2).
