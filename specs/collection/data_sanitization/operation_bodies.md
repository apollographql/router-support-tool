# Operation bodies in logs

## The problem

Although `router.yaml` never contains an operation body as a literal value, it does contain config that causes the router to write operation bodies into its own logs at runtime — query text, mutation text, and variables, which can carry customer PII or business-sensitive data. Note this was verified against `apollographql/router` at `v2.17.0`.

The base spec's `logs` collector captures router container logs (per `specs/collection/base_spec.md` → main table). If a customer has any of the settings below enabled, operation bodies — potentially including customer data passed as GraphQL variables — are already inside the log lines this tool collects.

### What causes operation bodies to show in logs

`telemetry.instrumentation.*` config, opt-in (not the router's default):

| Setting | Effect |
| --- | --- |
| `telemetry.instrumentation.events.router.response` (a `StandardEventConfig`, with `level`/`condition`) | Logs an event that includes an `http.response.body` attribute when the response-body extension is populated. Source: [`router/events.rs#L22-L128`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/router/events.rs#L22) |
| `telemetry.instrumentation.events.supergraph.request` / `.response` (also `StandardEventConfig`) | Serializes the *full* `supergraph_request.body()` — query text and variables — into the log line. Confirmed via `SupergraphEventsConfig` ([`supergraph/events.rs#L142-L148`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L142)), assembled under the `supergraph` field of the top-level `Events` struct ([`events.rs#L39-L48`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/events.rs#L39)). Behavior confirmed from [`supergraph/events.rs#L60-L90`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L60) |
| `telemetry.instrumentation.spans.supergraph.attributes.custom.<name>.query` (a `Query::String` selector), or `.query_variable: "<varName>"` | Attaches the raw query document, or a specific variable's value, to a span/log attribute under a customer-chosen name. Source: [`supergraph/selectors.rs#L58-L100`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/selectors.rs#L58) |

### Router Redaction

The router does have a real, built-in redaction mechanism for headers, but it doesn't cover operation bodies.

- **HTTP headers are masked before logging, by design.** The `RequestHeader`/`ResponseHeader` telemetry selectors carry an explicit `redact: Option<RedactMode>` field, and both the router-level and supergraph-level log events call `header_masking::masked_headers_for_log` before a header value is ever written to a log line. Sources: [`supergraph/selectors.rs#L86`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/selectors.rs#L86) (the `redact` field), [`supergraph/events.rs#L48`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L48) (the masking call on the request path).
- **`Query` and `QueryVariable` selectors have no equivalent field.** In the same enum, immediately next to `RequestHeader`, both variants carry only `{query, default}` and `{query_variable, default}` — no `redact` option exists on either. Source: [`supergraph/selectors.rs#L69-L79`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/selectors.rs#L69).
- **The standard request/response body events serialize the body raw, with no masking call at all.** `SupergraphEventRequest` does `serde_json::to_string(request.supergraph_request.body())` directly — [`supergraph/events.rs#L79`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L79), three lines after the header line above it, which *does* go through masking first. The router-level `HTTP_RESPONSE_BODY` attribute follows the identical pattern — pushed straight from the response-body extension with no redaction call.

So: if a customer enables header logging, whatever they've configured for `redact` already applies, and there's genuinely nothing for this project to add on top of that. If they enable any of the three settings above, the operation body and any named variable value are logged as-is — the absence of any masking here is confirmed directly from the code that logs them, not just inferred from the lack of a `redact` field on the selector.

## Options

1. **Detect and warn, don't attempt to mask.** This is more precisely an **analyzer** — troubleshoot.sh's mechanism for evaluating already-collected data and emitting a finding — not a redactor (redactors mask content, they don't produce findings) and not a `meta.json` field (the `router-diagnostics` chart can't see the router's own chart's `telemetry.instrumentation` settings at render time).
2. **Attempt log-content redaction.** This looks at first like it needs to pattern-match arbitrary GraphQL query/variable syntax inside free-form log text — a much harder problem than matching a known config field, since the shape of a customer's queries and variables is unbounded and customer-specific. **It's less open-ended than that, for two of the three settings above.** The router-level and supergraph-level body events push their content under fixed, hardcoded OpenTelemetry attribute keys, not customer-chosen ones:

   | Leak vector | Attribute key | Customer-controllable? |
   | --- | --- | --- |
   | `telemetry.instrumentation.events.router.response` | `http.response.body` — [`attributes.rs#L25`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/attributes.rs#L25) | No — fixed constant |
   | `SupergraphEventRequest`/`SupergraphEventResponse` | `http.request.body` / (response uses the same `http.response.body` key) — [`attributes.rs#L20`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/attributes.rs#L20) | No — fixed constant |
   | `telemetry.instrumentation.spans.supergraph.attributes.custom.<name>.query` / `.query_variable` | Whatever key name the customer writes in place of `<name>` | **Yes — the customer picks the key name** |

3. **Leave it as a documented risk** Consistent with `CLAUDE.md`'s instruction to flag a design gap rather than silently deciding it.

## Recommended Solution

**Option 2, log-content redaction — for the two leak vectors with fixed keys.** The reasoning above is what makes this a normal redaction problem rather than a genuinely open-ended one: the redactor never needs to know what a query looks like, only where the fixed key `http.request.body`/`http.response.body` sits in a log line.

**Two real constraints this redactor has to account for, both different from the `router.yaml` redactors elsewhere in this directory:**

- **Log files are genuinely line-delimited, unlike `router.yaml`.** The `logs` collector writes real newline-separated text files (`cluster-resources/pods/logs/<namespace>/<pod>/<container>.log`, symlinked at `router-runtime-logs/<pod>/<container>.log` — `specs/collection/output.md`), not JSON-escaped text embedded inside a larger document. So this redactor doesn't hit the `\n`-escaping problem every `router.yaml` redactor in this directory has to work around — single-line `regex` applies per real log line, cleanly.
- **The log line's exact JSON shape is not yet confirmed.** The router supports more than one log output format (`formatters/json.rs`, `formatters/text.rs`), and this redactor assumes the JSON formatter is in use, with `http.request.body`/`http.response.body` appearing as flat string-valued keys somewhere in that line. Whether that's actually true — flat vs. nested under a `fields`/`attributes` object, single-line-per-record vs. pretty-printed — was not traced further into the tracing-subscriber formatting layer and needs confirming against a real collected log line before this pattern is trusted. This is the same "draft until tested against a real bundle" status every redactor in this directory carries, not a new kind of risk.

```yaml
- name: router-log-request-body
  fileSelector:
    files:
      - "cluster-resources/pods/logs/*/*/*.log"
      - "router-runtime-logs/*/*.log"
  removals:
    regex:
      - redactor: '"http\.request\.body":"(?P<mask>(?:[^"\\]|\\.)*)"'
- name: router-log-response-body
  fileSelector:
    files:
      - "cluster-resources/pods/logs/*/*/*.log"
      - "router-runtime-logs/*/*.log"
  removals:
    regex:
      - redactor: '"http\.response\.body":"(?P<mask>(?:[^"\\]|\\.)*)"'
```

The capture group `(?:[^"\\]|\\.)*` matches a JSON string value correctly even when it contains escaped quotes (a GraphQL query embedding a string literal, for instance) — it consumes either a non-quote-non-backslash character or an escaped pair, so it doesn't terminate early on an escaped `\"` inside the body text.

### Notes

- **Required before this is considered done:** enable `telemetry.instrumentation.events.router.response` (and separately, the supergraph request/response events) against a router configured for JSON logging, send a query carrying a distinctive string in its body, collect a bundle, and confirm the value is masked in both `cluster-resources/pods/logs/.../*.log` and the `router-runtime-logs/` symlink target.

- **Text-format logging is deliberately out of scope, not an unresolved gap.** This pattern will not match a text-formatted log line at all — but the router's own format default is TTY-dependent, not fixed: `Format::default()` returns `Text` only when stdout is a terminal, and `Json` otherwise ([`logging.rs#L238-244`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/logging.rs#L238)). A router running in a Kubernetes container has no TTY attached to stdout, so JSON is the default in exactly the deployment context this tool targets — text format only appears if a customer deliberately overrides it.

- **What this still doesn't cover, and won't from this redactor alone:** the third leak vector — customer-named custom span/log attributes (`.custom.<name>.query`, `.custom.<name>.query_variable`) — cannot be caught by a fixed-key pattern, because the key name is whatever the customer chose to write in their own `router.yaml`. This is a genuinely different problem from the two above: there is no constant to search for. Catching it would require either parsing `router.yaml` first to discover which custom attribute names a given customer configured (a `router.yaml`-then-logs, two-stage dependency that troubleshoot.sh's redaction mechanism has no way to express since collectors and redactors don't take input from each other's output), or a much weaker heuristic pattern with a real false-positive/false-negative rate. **This gap is accepted** — the redactor above closes the two vectors that were closeable with a known key and this third one remains an open, documented risk regardless of what's implemented, until troubleshoot.sh itself gains a mechanism for redactors to depend on other collected data.
