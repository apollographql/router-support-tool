# Operation bodies in logs

## The Problem

`router.yaml` never holds an operation body itself, but it can enable config that makes the router log one at runtime — query text, mutation text, and variables, which can carry customer PII. Verified against `apollographql/router` at `v2.17.0`.

The base spec's `logs` collector captures router container logs (`specs/collection/base_spec.md` → main table). Operation bodies reach those logs only through opt-in `telemetry.instrumentation.*` config via a router-response event, a supergraph request/response event, or a customer-named custom span/log attribute (`.custom.<name>.query`/`.query_variable`). The first two write to fixed, known attribute keys, the third does not.

### Router-side redaction

The router masks headers before logging, but nothing equivalent exists for operation bodies. Confirmed against `v2.17.0`:

- **Headers are masked by design.** The `RequestHeader`/`ResponseHeader` selectors carry a `redact` field, and log events call `header_masking::masked_headers_for_log` before writing a value ([`selectors.rs#L86`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/selectors.rs#L86), [`events.rs#L48`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L48)). Whatever a customer configures here already applies — there's nothing for this project to add.
- **`Query` and `QueryVariable` selectors have no `redact` field** ([`selectors.rs#L69-L79`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/selectors.rs#L69)).
- **Body events serialize raw, with no masking call.** `SupergraphEventRequest` calls `serde_json::to_string` on the body directly ([`events.rs#L79`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L79)), three lines after the header path that *does* mask. The router-level `HTTP_RESPONSE_BODY` attribute is the same.

So if any of the three settings above is enabled, the operation body and variable values are logged as-is.

## The redactor

Redact the log content directly, for the two leak vectors whose attribute keys are fixed constants rather than customer-chosen:

| Leak vector | Attribute key |
| --- | --- |
| `telemetry.instrumentation.events.router.response` | `http.response.body` — [`attributes.rs#L25`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/attributes.rs#L25) |
| `SupergraphEventRequest`/`SupergraphEventResponse` | `http.request.body`, and the same `http.response.body` for the response — [`attributes.rs#L20`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/attributes.rs#L20) |

Unlike the `router.yaml` redactors above, this one has no escaping to work around. The `logs` collector writes real newline-separated text files (`cluster-resources/pods/logs/<namespace>/<pod>/<container>.log`, symlinked at `router-logs/<pod>/<container>.log` — `specs/collection/output.md`), so a single-line `regex` applies cleanly per log line.

```yaml
- name: router-log-request-body
  fileSelector:
    files:
      - "cluster-resources/pods/logs/*/*/*.log"
      - "router-logs/*/*.log"
  removals:
    regex:
      - redactor: '("http\.request\.body":")(?P<mask>(?:[^"\\]|\\.)*)(")'
- name: router-log-response-body
  fileSelector:
    files:
      - "cluster-resources/pods/logs/*/*/*.log"
      - "router-logs/*/*.log"
  removals:
    regex:
      - redactor: '("http\.response\.body":")(?P<mask>(?:[^"\\]|\\.)*)(")'
```

The capture group `(?:[^"\\]|\\.)*` matches a JSON string value correctly even when it contains escaped quotes (a GraphQL query embedding a string literal, for instance) — it consumes either a non-quote-non-backslash character or an escaped pair, so it doesn't terminate early on an escaped `\"` inside the body text.

### Notes

- **Text-format logging is out of scope because JSON is the default in a container.** `impl Default for Format` returns `Text` only when stdout is a terminal, `Json` otherwise ([`logging.rs#L238-246`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/logging.rs#L238)) — and a Kubernetes container has no TTY. A text pattern is also not one line away: JSON delimits the value with a closing quote, while text renders the attribute inline with nothing to stop the mask group at.

  **A customer who sets `format: text` therefore gets no body redaction at all, silently.** A real gap, and the argument for `specs/user_experience.md` to recommend JSON logging.

- **Open — these patterns assume `http.request.body`/`http.response.body` are flat, string-valued keys on the log line.** Whether they are flat or nested under a `fields`/`attributes` object has not been traced through the formatting layer. If nested, the patterns are wrong rather than merely untested. Settle it from one real log line.

- The third leak vector is not covered: customer-named span/log attributes (`.custom.<name>.query`, `.custom.<name>.query_variable`) have no fixed key to match — the name is whatever the customer wrote.

**Required before this is considered done:** with the supergraph request/response events enabled, run an operation whose variables carry a sentinel value and whose query embeds a string literal with an escaped quote. Confirm the sentinel is nowhere in the bundle, surrounding log fields (`level`, `target`, trace IDs) survive, and each line is **still valid JSON** — a mis-scoped pattern here yields unparseable logs rather than an obvious failure. Repeat with `format: text` to observe the documented gap.
