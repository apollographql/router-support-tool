# Operation bodies in logs

This one is a different kind of problem from the other four, and the difference matters: **`router.yaml` never contains an operation body as a literal value.** What it contains is *config that causes the router to write operation bodies into its own logs at runtime* — query text, mutation text, and variables, which can carry customer PII or business-sensitive data. There is no field to mask in the config; the thing that needs sanitizing is downstream of it, in log output this tool also collects.

Verified against `apollographql/router` at `v2.17.0`.

## What causes the leak

`telemetry.instrumentation.*` config, opt-in (not the router's default):

| Setting | Effect |
| --- | --- |
| `telemetry.instrumentation.events.router.response` (a `StandardEventConfig`, with `level`/`condition`) | Logs an event that includes an `http.response.body` attribute when the response-body extension is populated. Source: [`router/events.rs#L22-L128`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/router/events.rs#L22) |
| Supergraph request/response events (`SupergraphEventRequest`/`SupergraphEventResponse`) | Serializes the *full* `supergraph_request.body()` — query text and variables — into the log line. Source: [`supergraph/events.rs#L60-L90`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/events.rs#L60) |
| `telemetry.instrumentation.spans.supergraph.attributes.custom.<name>.query` (a `Query::String` selector), or `.query_variable: "<varName>"` | Attaches the raw query document, or a specific variable's value, to a span/log attribute under a customer-chosen name. Source: [`supergraph/selectors.rs#L58-L100`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/telemetry/config_new/supergraph/selectors.rs#L58) |

None of these settings hold a secret themselves — they're booleans and selector expressions. A regex redactor on `router.yaml` can, at most, detect that one of them is turned on. It cannot mask the data that setting causes to leak, because that data doesn't exist in the config file at all.

## Why this is relevant to `specs/collection/base_spec.md`, not just this directory

**The base spec's `logs` collector captures router container logs unconditionally** (per `specs/collection/base_spec.md` → main table). If a customer has any of the settings above enabled, operation bodies — potentially including customer data passed as GraphQL variables — are already inside the log lines this tool collects, before any redaction in this directory ever runs. This is a real, current gap between what the base spec collects and what it redacts:

- **No custom redactor in this repo currently targets router log content for operation-body patterns.** The redactors in this directory all target `router.yaml`, not `router-runtime-logs/`.
- **A redactor that could catch this would need to pattern-match arbitrary GraphQL query/variable syntax inside free-form log text** — a much harder, higher-false-positive/false-negative problem than matching a known config field, because the shape of a customer's queries and variables is unbounded and customer-specific.

This needs a design decision, not an assumption one way or the other — and the three options below aren't evenly weighted, because two of them require reopening a decision already made elsewhere, not just writing new content:

1. **Detect and warn, don't attempt to mask.** This is more precisely an **analyzer** — troubleshoot.sh's mechanism for evaluating already-collected data and emitting a finding — not a redactor (redactors mask content, they don't produce findings) and not a `meta.json` field (the `router-diagnostics` chart can't see the router's own chart's `telemetry.instrumentation` settings at render time, the same cross-chart blindness that ruled out `expected_absences` in `specs/collection/meta_json.md`). **`specs/versions/v1.md` puts analyzers out of scope for v1 entirely**, so adopting this option isn't just "write a check" — it's reopening that scope decision for this one case.
2. **Attempt log-content redaction.** Write a best-effort pattern for common GraphQL log-line shapes (e.g., a `"query":` or `"variables":` JSON key inside a structured log line). Higher engineering cost, and a false negative here is silent and undetectable from the bundle alone — the same silent-failure risk every redactor in this directory carries, but with a much larger blast radius if it's wrong, since operation bodies can carry real customer data. **This is the only one of the three that fits within v1's current constraints as they stand** — it's a redactor, not an analyzer, and needs no render-time visibility into the router's own config.
3. **Leave it as a documented risk, unaddressed for v1.** Consistent with `CLAUDE.md`'s instruction to flag a design gap rather than silently deciding it — this doc is not proposing which of the three is correct.

**Open, and blocking a real redactor rather than just a documented one:** which of the above this project adopts. Until that's decided, the honest state is that operation bodies reaching logs are a known, collected, unredacted risk whenever a customer has enabled any of the telemetry settings above — this should be called out in `specs/collection/base_spec.md`'s `logs` collector row or its own subsection, not left implicit.

## What this doc does not attempt

No redactor YAML is proposed here, deliberately — writing one before the detect-vs-mask-vs-defer decision above is made would encode an unreviewed design choice into a "redactor" that either does very little (option 1) or takes on real false-negative risk (option 2). See `overview.md` for why every redactor in this directory needs a verified test before being trusted; this is the one case in this set where that testing gap is a security decision, not an implementation detail.
