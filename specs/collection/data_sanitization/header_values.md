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
      - redactor: '(insert:\\n(?:\s*name:\s*\\?"?[^"\\\n]*\\?"?\\n)*\s*value:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(insert:\s*\{(?:[^}\\]|\\")*?value:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?(?:[^}\\]|\\")*?\})'
      - redactor: '(insert:\\n(?:\s*(?:name|path):\s*\\?"?[^"\\\n]*\\?"?\\n)*\s*default:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(insert:\s*\{(?:[^}\\]|\\")*?default:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?(?:[^}\\]|\\")*?\})'
- name: router-headers-propagate-default
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(propagate:\\n(?:\s*(?:named|rename):\s*\\?"?[^"\\\n]*\\?"?\\n)*\s*default:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(propagate:\s*\{(?:[^}\\]|\\")*?default:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?(?:[^}\\]|\\")*?\})'
```

**Notes:**

- Two patterns per field, because YAML permits both block style (`insert:` / `name:` / `value:` on separate lines) and flow style (`insert: {name: x-api-key, value: secret}`), and there's no way to know ahead of time which one a customer's `router.yaml` uses.
- **Block-style is order-independent, not just flow-style.** RE2 has no lookbehind, so a block pattern can't search backward for a key it depends on — but it doesn't need to: each pattern anchors on `insert:\n`/`propagate:\n` and then matches zero or more of the operation's *other* possible keys (`name`/`path` for `insert`, `named`/`rename` for `propagate`), in any order and combination, before matching the target field. This is safe because each operation variant has a small, fixed set of possible keys (enforced by the router's own serde schema) — there's nothing else the "zero or more" group could accidentally consume past. Matters in practice: the official Apollo Router Helm chart's `templates/configmap.yaml` round-trips `values.yaml` through Helm's own YAML marshaling, which re-serializes every map alphabetically (`default` sorts before `name`/`named`) — so a naive order-dependent pattern would silently fail to redact `insert.default`/`propagate.default` on every single official-chart deployment that uses them, not just on an unconventionally-authored `router.yaml`.
- `insert.default`'s block pattern allows any number of `name:`/`path:` lines (in any order) before `default:`. `propagate.default`'s allows any number of `named:`/`rename:` lines before `default:`, since `rename` is optional on `Propagate::Named`.

**Required before this is considered done:** collect against a router with each of the three fields set to a distinct value — `insert.value`, `insert.default` (with the JSONPath deliberately unresolvable), and `propagate.default` (with the source header absent) — and confirm all three are masked in the `configMap`/`clusterResources` output, **under both the raw-manifest tier (hand-authored key order) and the official Apollo Router Helm chart tier (Helm's alphabetically re-serialized key order)** - the two tiers exercise genuinely different key orderings, and only the official chart's proves the block-style patterns are actually order-independent rather than merely written to look that way.

## What's deliberately left visible

Header *names* — `propagate.named`, `remove`, `rename`, and the `name` field of `insert` — are left visible in every operation. Which headers the router forwards or strips is routing/security-posture information a support engineer needs to see. Only the literal values a customer chose to hardcode are masked.
