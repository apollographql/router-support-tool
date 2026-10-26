---
category: test
breaking: false
---

Test every shape of the response_cache shared_key redactor and sweep the whole bundle for it

A new `test-shared-key-redactor` check runs the redactor's patterns, read from the rendered
chart, over the shapes the key can take: unquoted, quoted (plain and JSON-escaped), flow
style, JSON, the `last-applied-configuration` annotation, and the empty and bare forms that
must be left alone. The RTF scenario also now searches the entire extracted bundle for the
shared key sentinels instead of only the dedicated ConfigMap file.
