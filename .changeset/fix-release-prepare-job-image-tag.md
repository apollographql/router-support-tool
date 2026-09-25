---
category: docs
breaking: false
---

Clarify job.image.tag's meaning and keep it in lock-step with the release version

`release_prepare.yaml` bumps `values.yaml`'s `job.image.tag` alongside `Chart.yaml`'s `version:`
at release time, since `release_dockerhub` publishes the Job image under the release version —
not a troubleshoot.sh version — so this is what keeps the chart's default installable. Corrected
`values.yaml`'s comment (and the generated README) to describe what the tag actually tracks.
