# Response cache invalidation shared key

## The Problem

`response_cache` has an HTTP invalidation endpoint and each subgraph's `invalidation` block carries a literal `shared_key`, the secret a caller must present to use that endpoint. Anyone holding it can purge the router's cache. The router refuses to start with invalidation enabled unless the `all` block sets a non-empty `shared_key` so a literal value in `router.yaml` is the normal case, not an edge case.

The field lives at:

- **`response_cache.subgraph.all.invalidation.shared_key`**
- **`response_cache.subgraph.subgraphs.<name>.invalidation.shared_key`** — a per-subgraph override.

Verified against `apollographql/router` at `v2.17.0` (the field exists in `plugins/response_cache/plugin.rs`) and `v3.0.0-preview.0` (the generated config schema marks it `x-apollo-secret: true`, with a default of `""`).

## Redactor: any file in the bundle

Single-line `regex` with a `mask` capture group. Three patterns, one per shape the field can take:

```yaml
- name: router-response-cache-invalidation-shared-key
  removals:
    regex:
      - redactor: '(shared_key:\s*(?:\\")?)(?P<mask>[^"\\\s][^"\\]*)(\\?"?)'
      - redactor: '("shared_key":\s*")(?P<mask>[^"\\]+)(")'
      - redactor: '(\\"shared_key\\":\s*\\")(?P<mask>[^"\\]+)(\\")'
```

| Pattern | Shape it matches | Where it shows up |
| --- | --- | --- |
| 1 | YAML text: `shared_key: x`, either raw or inside a JSON-escaped string | `router.yaml` in `cluster-resources/configmaps/*.json` and `configmaps/*/*.json`; `helm/*.json` once a `yamlPath` rule has re-serialized it as YAML |
| 2 | Pretty or compact JSON: `"shared_key": "x"` | Structured JSON output, such as the `helm` collector's values |
| 3 | JSON inside a JSON string: `\"shared_key\":\"x\"` | The `kubectl.kubernetes.io/last-applied-configuration` annotation |

### Notes

- **Deliberately has no `fileSelector` so it runs against every file in the bundle.** This matches `redis_credentials.md`'s URL rule and `secret_shaped_env_vars.md`, and is what reaches the `helm` collector's output and the annotation without enumerating those paths. `shared_key` appears exactly once in the `v3.0.0-preview.0` config schema, so over-redaction is unlikely. A `shared_key:` in unrelated output, such as a CRD schema example, is masked the same as a real one.

- **One pattern covers block and flow style.** The mask stops at the first `"` or `\`, so it ends at a closing quote or at the literal `\n` that ends a block-style line, and needs no key-order modelling. Flow style still matches. The value does not need to be followed by a newline, so a `router.yaml` whose last line is the `shared_key` (a `|-` block scalar strips the trailing newline) is masked.

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
- another subgraph with the key unset or `""`.

Confirm every sentinel is absent, the other `invalidation` fields (`enabled`, `indexes`) survive in the block-style cases, and the unset subgraph is not mangled (no mask spliced into `shared_key: ""`). Also confirm masking on each non-ConfigMap surface: the `helm` collector's output (set the key through the official chart's `values.yaml`) and the `last-applied-configuration` annotation (deploy with `kubectl apply`). Run the `helm` check with the redactors in both orders, since a `yamlPath` rule rewrites that file from JSON to YAML and the surviving shape decides whether pattern 1 or 2 fires.

Also confirm `redactUri` reports a positive `CharactersRemoved` for this rule (`overview.md` → Knowing whether a redactor fired).

## What's deliberately left visible

Everything else in `response_cache` — `enabled`, `ttl`, `private_id`, `indexes`, the top-level `response_cache.invalidation` endpoint's `listen` and `path`, `cdn_invalidation`, and the Redis block's `urls`/`namespace`/`tls`/timeouts.
