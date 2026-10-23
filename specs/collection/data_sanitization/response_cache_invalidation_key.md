# Response cache invalidation shared key

## The Problem

`response_cache` has an HTTP invalidation endpoint and each subgraph's `invalidation` block carries a literal `shared_key`, the secret a caller must present to use that endpoint. Anyone holding it can purge the router's cache. The router refuses to start with invalidation enabled unless the `all` block sets a non-empty `shared_key` so a literal value in `router.yaml` is the normal case, not an edge case.

The field lives at:

- **`response_cache.subgraph.all.invalidation.shared_key`**
- **`response_cache.subgraph.subgraphs.<name>.invalidation.shared_key`** — a per-subgraph override.
- **`response_cache.connector.all.invalidation.shared_key`** and **`response_cache.connector.sources.<subgraph>.<source>.invalidation.shared_key`**. The connector's `invalidation` block reuses the subgraph config type (`SubgraphInvalidationConfig` in `plugins/response_cache/connectors.rs`).

Verified against `apollographql/router` at `v2.17.0` (the field exists in `plugins/response_cache/plugin.rs`) and `v3.0.0-preview.0` (the generated config schema marks it `x-apollo-secret: true`, with a default of `""`).

## Redactor: any file in the bundle

Single-line `regex` with a `mask` capture group. Three patterns, one per shape the field can take:

```yaml
- name: router-response-cache-invalidation-shared-key
  removals:
    regex:
      - redactor: '(shared_key:\s*(?:\\*")?)(?P<mask>[^"\\\s][^"\\]*)(\\*"?)'
      - redactor: '("shared_key":\s*")(?P<mask>[^"\\]+)(")'
      - redactor: '(\\"shared_key\\":\s*\\")(?P<mask>[^"\\]+)(\\")'
```

| Pattern | Shape it matches | Where it shows up |
| --- | --- | --- |
| 1 | YAML text: `shared_key: x` or `shared_key: "x"`, either raw or inside a JSON-escaped string (`\"x\"`) | `router.yaml` in `cluster-resources/configmaps/*.json` and `configmaps/*/*.json`. The raw quoted form (`shared_key: "x"`) is not emitted by any collector today. |
| 2 | Pretty or compact JSON: `"shared_key": "x"` | Standalone JSON output. No collector emits this today; it covers a future collector that does. |
| 3 | JSON inside a JSON string: `\"shared_key\":\"x\"` | The `kubectl.kubernetes.io/last-applied-configuration` annotation |

### Notes

- **Deliberately has no `fileSelector` so it runs against every file in the bundle.** This matches `redis_credentials.md`'s URL rule and `secret_shaped_env_vars.md`, and is what reaches the annotation without enumerating paths, and any collector added later. `shared_key` appears exactly once in the `v3.0.0-preview.0` config schema, so over-redaction is unlikely. A `shared_key:` in unrelated output, such as a CRD schema example, is masked the same as a real one.

- **One pattern covers block and flow style.** The mask stops at the first `"` or `\`, so it ends at a closing quote or at the literal `\n` that ends a block-style line, and needs no key-order modelling. Flow style still matches. The value does not need to be followed by a newline, so a `router.yaml` whose last line is the `shared_key` (a `|-` block scalar strips the trailing newline) is masked.

- **A quoted value is masked however many times its quotes are escaped.** The optional opening quote is `\\*"`, any number of backslashes then a quote. That covers `shared_key: "x"` (plain; no v1 collector emits it, so `mise run test-shared-key-redactor` is its only coverage), `shared_key: \"x\"` (inside a JSON string, the `router.yaml` ConfigMap form) and `shared_key: \\\"x\\\"` (the `last-applied-configuration` annotation, where that JSON string is itself nested inside a JSON string). A single optional backslash missed the last form, so a quoted key leaked through the annotation in `cluster-resources/configmaps/*.json`.

- **An empty or absent key is left alone.** `shared_key: ""` (the schema default), `"shared_key": ""` and a bare `shared_key:` do not match, in any of the three patterns. A bundle whose `invalidation` block shows `shared_key: ""` means no key was set.

- **Over-masks in a few shapes:**
  - **Unquoted flow style.** `{enabled: true, shared_key: x, ...}` masks from the value to the next `"` or `\`, so the closing `}` and any later flow keys are masked too.
  - **A trailing comment.** `shared_key: x # note` masks the comment with the value.
  - **`${env.*}` indirection.** `shared_key: ${env.INVALIDATION_KEY}` is masked as well.

## Required before this is considered done

Collect against a router (Router 2.x and the 3.0 preview) with `response_cache` enabled and:

- a `shared_key` set to a distinct sentinel in `subgraph.all.invalidation`,
- a different sentinel in one `subgraph.subgraphs.<name>.invalidation` override (quoted),
- a third in flow style,
- a case with `shared_key` as the last line of `router.yaml` with no trailing newline,
- another subgraph with the key unset or `""`,
- on Router `v2.19.0`+, a sentinel in `connector.all.invalidation` and a quoted one in a `connector.sources.<subgraph>.<source>.invalidation` override.

Confirm every sentinel is absent, the other `invalidation` fields (`enabled`, `indexes`) survive in the block-style cases, and the unset subgraph is not mangled (no mask spliced into `shared_key: ""`). Also confirm masking on the non-ConfigMap surface: the `last-applied-configuration` annotation (deploy with `kubectl apply`), by searching the whole extracted bundle for the sentinels. The base spec has no `helm` collector, so there is no `helm/*.json` surface to check.

Also confirm `redactUri` reports a positive `CharactersRemoved` for this rule (`overview.md` → Knowing whether a redactor fired).

## What's deliberately left visible

Everything else in `response_cache` — `enabled`, `ttl`, `private_id`, `indexes`, the top-level `response_cache.invalidation` endpoint's `listen` and `path`, `cdn_invalidation`, and the Redis block's `urls`/`namespace`/`tls`/timeouts.
