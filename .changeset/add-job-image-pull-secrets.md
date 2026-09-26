---
category: feat
breaking: false
---

Add job.imagePullSecrets to router-diagnostics-chart

Lets you authenticate to a private mirror when overriding job.image.repository. Previously
there was no way to supply pull credentials for the Job's image at all. Standard Kubernetes
imagePullSecrets shape is attached to the Job's pod spec and omitted from the rendered manifest when
left empty. The default, published image needs no credentials to pull.
