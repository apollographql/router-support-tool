---
category: fix
breaking: false
---

Fix router-subgraph-url redactor cascading past its own block

`override_subgraph_url`'s custom redactor had no explicit terminator on its mask and
relied on finding a de-indented line to know where to stop. A troubleshoot.sh built-in
redactor (matching connection-string-shaped URLs, which a typical
`scheme://user:pass@host:port/path` subgraph override satisfies) runs first and
independently over-redacts past the URL's closing quote into the next key's name. Once
that key name was gone, our own rule had no de-indented anchor left to stop at, and its
greedy mask cascaded through everything still-indented after it. In the worst case, an
entire `tls` block's certificates and keys.

`router-subgraph-url`'s regex now anchors each entry's mask on its own closing
delimiter instead: a literal closing quote for quoted values, or the line's own end for
unquoted values that don't contain `@`.

This does not fix the underlying troubleshoot.sh built-in behavior, it only stops our
own rule from compounding it. Even with this fix, the built-in can still eat past a
*credentialed* URL's own closing quote.
