---
category: docs
breaking: false
---

Update comment and document manual bundle retrieval when job.storage is unconfigured

Leaving `job.storage.provider` unset is a supported default and explicitly documented this
path for bundle retrieval: users must retrieve the bundle with `kubectl cp` before 
`job.ttlSecondsAfterFinished` elapses  (default one hour).
