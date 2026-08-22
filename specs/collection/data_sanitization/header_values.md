# Header values in config

## The Problem

The router's `headers` plugin lets an operator set literal HTTP header values in `router.yaml`. That's the one place in this plugin's config a real secret can appear — everything else in it is header names or forwarding rules, never values.

Verified against `apollographql/router` at `v2.17.0`.

### What's in the block, and which parts are actually sensitive

`headers.all.request`/`.response` and the per-subgraph equivalent (`headers.subgraphs.<name>.request`/`.response`) hold a list of operations. The `Operation` enum is `insert | remove | propagate`:

| Operation | What it does | Sensitive? |
| --- | --- | --- |
| `propagate` | Forwards an existing header (by name or regex) from request to response, or vice versa | No — never carries a literal value |
| `remove` | Strips a header by name or regex | No |
| `insert` — `Static` variant | Sets a header to a **literal, hardcoded value**: `insert: {name: "x-api-key", value: "literal-secret"}` | **Yes.** This is the one shape where a customer would plausibly hardcode a credential (an API key sent to a subgraph, for instance) directly into the spec. |
| `insert` — `FromContext` / `FromBody` variants | Sets a header from a runtime value (request context, request body field) | No literal value exists in the YAML — nothing to redact here |

Source: [`headers/mod.rs#L96-L182`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/headers/mod.rs#L96) — `InsertStatic{name: HeaderName, value: HeaderValue}` is the exact field carrying the literal.

**This is not the only place a literal header value can appear.** `authentication.router.jwt.jwks[].headers[]` (see `jwt_and_auth_config.md`) uses the identical `{name, value}` shape for a different purpose — headers sent when fetching a JWKS URL. The two are unrelated in the config tree and need separate redactor rules (different YAML paths), even though the underlying risk and pattern shape are the same.

## Redactor: `router.yaml` (`configMap`/`clusterResources` output)

Single-line `regex` with a `mask` capture group, for the same reason given in `overview.md`: the config is embedded as JSON-escaped text, so `yamlPath` can't reach a single field inside it.

```yaml
- name: router-headers-insert-static-value
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: 'insert:\\n\s*name:\s*"?[^"\\\n]*"?\\n\s*value:\s*"?(?P<mask>[^"\\\n]*?)"?'
      - redactor: 'insert:\s*\{[^}\\]*?value:\s*"?(?P<mask>[^",}\\]*)"?[^}\\]*?\}'
```

**Two patterns, because block-style and flow-style YAML are both real possibilities and neither can be ruled out by checking source.** Unlike the `helm`-output serialization question elsewhere in this directory, which mechanical checking resolved definitively, whether a given `router.yaml` writes `insert` as

```yaml
- insert:
    name: x-api-key
    value: secret
```

or as `insert: {name: x-api-key, value: secret}` is entirely up to the customer or chart template that authored it — YAML permits both, and this project has no control over or visibility into that choice ahead of time. So rather than picking one and treating the other as an accepted gap, both patterns are included in the same redactor: the first (unchanged from before) targets the block-style, `key:`/`value:`-on-separate-lines shape; the second targets flow-style, matching `value:` anywhere between the `{` and `}` regardless of whether `name` comes before or after it, since YAML flow-map key order isn't guaranteed either. Unlike `subgraph_urls.md`'s redactor, neither pattern is order/structure-agnostic on its own — together, they cover the two structures YAML actually allows for this field, rather than one of them.

**Important Notes:** 
- Both patterns need independent verification, and covering both structures doesn't mean either is confirmed correct.
- **Required before this is considered done:** collect against a router configured with a hardcoded `insert` header value written in block style, and a separate collection with it written in flow style, and confirm each pattern matches its corresponding case in real collected output.

## Redactor: the `helm` collector's output

**Not a two-line regex — `yamlPath`, because the field's exact location is known, not guessed.** We choose not to use a `selector`/`redactor` pair matching any `"name": "..."` line in the file, because that's too broad and would mask whatever follows *any* `{name, value}`-shaped pair in the whole Helm values dump, including ones that have nothing to do with header redaction (an env var list, an unrelated annotation, anything else shaped like `{name, value}`). Per `overview.md`, `helm/*.json` is genuine structured JSON, not a string blob — exactly the case where `yamlPath` is the right tool, since it can target a specific field by path rather than pattern-matching text. The router chart nests all router config under `.Values.router.configuration` (confirmed elsewhere in this doc set, e.g. `router.configuration.telemetry.exporters.metrics.prometheus.enabled` — `specs/deployment/v1/v1.md`), so the `headers` config's location is a known chart convention, not something this pattern has to guess at:

```yaml
- name: router-headers-insert-static-value-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    yamlPath:
      - "releaseHistory.*.values.router.configuration.headers.all.request.*.insert.value"
      - "releaseHistory.*.values.router.configuration.headers.all.response.*.insert.value"
      - "releaseHistory.*.values.router.configuration.headers.subgraphs.*.request.*.insert.value"
      - "releaseHistory.*.values.router.configuration.headers.subgraphs.*.response.*.insert.value"
```

**Important Notes:**

- Four paths, one per `all`/`subgraphs` × `request`/`response` combination — `subgraphs.*` wildcards over subgraph names, `request.*`/`response.*` wildcards over the operation list's array index, and only the `insert.value` leaf is masked, leaving `insert.name` (and every `propagate`/`remove` entry) untouched. This is more precise than a two-line regex, at the cost of depending on `releaseHistory`'s array shape and the `router.configuration` nesting convention holding — both stated as fact above, not verified against a real collected file.

- **Required before this is considered done:** collect a bundle with a hardcoded `insert` header value configured, and confirm each path actually matches and masks in real collected output — including checking `helm/*.json`'s actual top-level shape (is it really `releaseHistory`, an array, at that nesting?) before trusting any of the four paths.

## What's deliberately left visible

Header *names* in every operation — `propagate`, `remove`, and the `name` field of `insert` — are left visible. Which headers the router forwards or strips is routing/security-posture information a support engineer needs to see. Only the literal secret a customer chose to hardcode as a value is masked.
