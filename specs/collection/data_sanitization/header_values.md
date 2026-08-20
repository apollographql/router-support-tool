# Header values in config

The router's `headers` plugin lets an operator set literal HTTP header values in `router.yaml`. That's the one place in this plugin's config a real secret can appear — everything else in it is header *names* or forwarding rules, never values.

Verified against `apollographql/router` at `v2.17.0`.

## What's in the block, and which parts are actually sensitive

`headers.all.request`/`.response` and the per-subgraph equivalent (`headers.subgraphs.<name>.request`/`.response`) hold a list of operations. The `Operation` enum is `insert | remove | propagate`:

| Operation | What it does | Sensitive? |
| --- | --- | --- |
| `propagate` | Forwards an existing header (by name or regex) from request to response, or vice versa | No — never carries a literal value |
| `remove` | Strips a header by name or regex | No |
| `insert` — `Static` variant | Sets a header to a **literal, hardcoded value**: `insert: {name: "x-api-key", value: "literal-secret"}` | **Yes.** This is the one shape where a customer would plausibly hardcode a credential (an API key sent to a subgraph, for instance) directly into the spec. |
| `insert` — `FromContext` / `FromBody` variants | Sets a header from a runtime value (request context, request body field) | No literal value exists in the YAML — nothing to redact here |

Source: [`headers/mod.rs#L96-L182`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/headers/mod.rs#L96) — `InsertStatic{name: HeaderName, value: HeaderValue}` is the exact field carrying the literal.

**This is not the only place a literal header value can appear.** `authentication.router.jwt.jwks[].headers[]` (see `jwt_and_auth_config.md`) uses the identical `{name, value}` shape for a different purpose — headers sent when fetching a JWKS URL. The two are unrelated in the config tree and need separate redactor rules (different YAML paths), even though the underlying risk and pattern shape are the same.

## Redactor

Single-line `regex` with a `mask` capture group, for the same reason given in `overview.md`: the config is embedded as JSON-escaped text, so `yamlPath` can't reach a single field inside it.

```yaml
- name: router-headers-insert-static-value
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: 'insert:\\n\s*name:\s*"?[^"\\\n]*"?\\n\s*value:\s*"?(?P<mask>[^"\\\n]*?)"?'
```

**The `helm/` paths are scoping-only, not a confirmed match.** Per `jwt_and_auth_config.md`, the `helm` collector (`collectValues: true`) captures a second copy of these values from the Helm layer, in a format that wasn't verified during this directory's research and is unlikely to be the same block-style shape targeted above.

**An earlier draft of this pattern assumed a flow-style, no-space shape (`insert:{name:"...",value:"..."}`) — that was wrong, for the same reason called out in `jwt_and_auth_config.md`.** `router.yaml` reaches the bundle as the literal text of the ConfigMap value as authored, JSON-escaped, not re-serialized into JSON-object or flow-map form. Block-style YAML — `insert:` then `name:` and `value:` as separate, indented, `\n`-separated lines — is what this pipeline actually preserves, and is also the idiomatic way to author this config, so it's the shape this pattern now targets.

**This is still a draft, and carries one risk the JWT/AWS redactors don't have to the same degree: YAML permits writing `insert` in flow style too** (`insert: {name: x-api-key, value: secret}`), and which style a given `router.yaml` uses depends on how the customer or chart template originally wrote it — this project doesn't control that. The pattern above only matches the block-style case. Unlike `subgraph_urls.md`'s redactor, which matches a credential-shaped substring regardless of surrounding structure, this one is anchored to a specific key layout and will silently fail to match a flow-style `insert` — no error, the value just stays in the bundle. **Required before this is considered done:** collect against a router configured with a hardcoded `insert` header value, get a real bundle, and confirm both that the block-style assumption holds and that the pattern actually matches — and if flow-style authoring turns out to be plausible for this project's customers, this needs a second pattern for that case, not a replacement of this one.

## What's deliberately left visible

Header *names* in every operation — `propagate`, `remove`, and the `name` field of `insert` — are left visible. Which headers the router forwards or strips is routing/security-posture information a support engineer needs to see; only the literal secret a customer chose to hardcode as a value is masked.
