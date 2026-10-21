---
category: fix
breaking: false
---

Redact the response cache invalidation shared key

`response_cache.subgraph.*.invalidation.shared_key` is the key a caller must present to
the router's cache invalidation endpoint so anyone holding it can purge cached
responses. None of the existing redactors matched it. Therefore, a literal value in
`router.yaml` was collected into the bundle unmasked. A new redactor masks it in the
collected `router.yaml`, in the `helm` collector's output, and in the
`last-applied-configuration` annotation. An empty `shared_key: ""` is left alone.
