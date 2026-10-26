---
category: test
breaking: false
---

Run the Router 2 full-redaction RTF variant on v2.19.0, including the response cache connector

Router 2.19.0 adds `response_cache.connector`, which earlier versions reject. The Router 2 `full`
redaction fixtures now carry a connector block, so the RTF test plan runs them on `v2.19.0` and
moves `v2.17.0` to the base config like the other earlier 2.x versions. The connector block has
an invalidation `shared_key` (unquoted on `all`, quoted on a source) and Redis credentials as a
URL-embedded password on `all` and as separate username and password fields on a source.
