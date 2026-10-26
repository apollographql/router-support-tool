---
category: test
breaking: false
---

Test against Router v2.19.0, including the response cache connector redaction

The RTF test plan adds a `v2.19.0` variant with full redaction. Router 2.19.0 adds
`response_cache.connector`. The variant has its own fixtures with a connector block
and Redis credentials as a URL-embedded password on `all,` and as separate
username and password fields on a source.
