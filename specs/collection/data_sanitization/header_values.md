# Header values in config

## The Problem

The router's `headers` plugin supports several operations. Most carry only header names or routing rules. Three fields, across two of these operations, can also hold a literal value ([`headers/mod.rs#L128-224`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/headers/mod.rs#L128), verified at `v2.17.0`):

- **`insert.value`** (the `Static` variant) — a hardcoded header value.
- **`insert.default`** (the `FromBody` variant) — the literal fallback used when the configured JSONPath doesn't resolve in the request body.
- **`propagate.default`** (the `Named` variant) — the literal fallback used when the source header isn't present to propagate.

`insert.from_context` has no such field — it always reads a runtime value, never a literal.

## Redactor: `router.yaml` (`configMap`/`clusterResources` output)

Single-line `regex` with a `mask` capture group. Six patterns: block-style and flow-style for each of the three fields above.

```yaml
- name: router-headers-insert-literal-values
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(insert:\\n\s*name:\s*\\?"?[^"\\\n]*\\?"?\\n\s*value:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(insert:\s*\{(?:[^}\\]|\\")*?value:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?(?:[^}\\]|\\")*?\})'
      - redactor: '(insert:\\n\s*name:\s*\\?"?[^"\\\n]*\\?"?\\n\s*path:\s*\\?"?[^"\\\n]*\\?"?\\n\s*default:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(insert:\s*\{(?:[^}\\]|\\")*?default:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?(?:[^}\\]|\\")*?\})'
- name: router-headers-propagate-default
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(named:\s*\\?"?[^"\\\n]*\\?"?\\n\s*(?:rename:\s*\\?"?[^"\\\n]*\\?"?\\n\s*)?default:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(propagate:\s*\{(?:[^}\\]|\\")*?default:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?(?:[^}\\]|\\")*?\})'
```

**Notes:**

- Two patterns per field, because YAML permits both block style (`insert:` / `name:` / `value:` on separate lines) and flow style (`insert: {name: x-api-key, value: secret}`), and there's no way to know ahead of time which one a customer's `router.yaml` uses.
- **Flow-style matches regardless of key order, block-style requires `name:`/`named:` to come first.** RE2 has no lookbehind, so the block pattern can't search backward for the key it depends on. **Accepted limitation:** a block entry that writes `value:`/`default:` before `name:`/`named:` is not masked.
- `insert.default`'s block pattern expects `path:` between `name:` and `default:`. `path` is required on the `FromBody` variant so it is always present, but **serde accepts mapping keys in any order** — the pattern matches the conventional authoring order, not a structural guarantee. Any other order won't match, same limitation as above.
- `propagate.default`'s block pattern allows an optional `rename:` line between `named:` and `default:`, since `Propagate::Named` has an optional `rename` field that a customer may or may not include.

## Redactor: the `helm` collector's output

`helm/*.json` is structured JSON, so `yamlPath` masks each field by its exact path — order-independent, and precise rather than key-name matching:

```yaml
- name: router-headers-insert-literal-values-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    yamlPath:
      - "*.releaseHistory.*.values.router.configuration.headers.all.request.*.insert.value"
      - "*.releaseHistory.*.values.router.configuration.headers.all.response.*.insert.value"
      - "*.releaseHistory.*.values.router.configuration.headers.subgraphs.*.request.*.insert.value"
      - "*.releaseHistory.*.values.router.configuration.headers.subgraphs.*.response.*.insert.value"
      - "*.releaseHistory.*.values.router.configuration.headers.all.request.*.insert.default"
      - "*.releaseHistory.*.values.router.configuration.headers.all.response.*.insert.default"
      - "*.releaseHistory.*.values.router.configuration.headers.subgraphs.*.request.*.insert.default"
      - "*.releaseHistory.*.values.router.configuration.headers.subgraphs.*.response.*.insert.default"
- name: router-headers-propagate-default-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    yamlPath:
      - "*.releaseHistory.*.values.router.configuration.headers.all.request.*.propagate.default"
      - "*.releaseHistory.*.values.router.configuration.headers.all.response.*.propagate.default"
      - "*.releaseHistory.*.values.router.configuration.headers.subgraphs.*.request.*.propagate.default"
      - "*.releaseHistory.*.values.router.configuration.headers.subgraphs.*.response.*.propagate.default"
```

`Insert` and `Propagate` are both `#[serde(untagged)]` ([`headers/mod.rs#L164`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/headers/mod.rs#L164), [`headers/mod.rs#L192`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/headers/mod.rs#L192)), so each variant's fields serialize flatly under `insert:`/`propagate:` — no variant-name segment in the path.

**Required before this is considered done:** collect against a router with each of the three fields set to a distinct value — `insert.value`, `insert.default` (with the JSONPath deliberately unresolvable), and `propagate.default` (with the source header absent) — and confirm all three are masked in both the `configMap`/`clusterResources` output and the `helm` collector's output.

## What's deliberately left visible

Header *names* — `propagate.named`, `remove`, `rename`, and the `name` field of `insert` — are left visible in every operation. Which headers the router forwards or strips is routing/security-posture information a support engineer needs to see. Only the literal values a customer chose to hardcode are masked.
