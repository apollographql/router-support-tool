---
category: docs
breaking: false
---

Document supported router versions and the response cache redaction

The overview and getting-started pages now state that the tool supports Router 2.4.0
through the 3.0.0 preview. The redaction descriptions now include the response cache's
invalidation `shared_key`, its Redis config and the OTLP gRPC TLS key, and the Data
Collected page notes that a key set through an environment variable, or left empty,
isn't masked in `router.yaml`.
