# Redis credentials in cache config

## The Problem

`router.yaml`'s Redis cache config can carry a literal credential two ways: embedded in a connection URL (`redis://user:pass@host:6379`), or as separate `username`/`password` fields. Nothing in the router requires one over the other, and both can be set at once.

The `helm`/`configMap` collectors capture `router.yaml` as written, so either form is collected into the bundle. This applies to all three Redis-backed caches — query-plan, APQ, and entity caching — which share the same config shape. Verified against `apollographql/router` at `v2.17.0`.

## Redactor: embedded URL credentials

Single-line `regex` with a `mask` capture group:

```yaml
- name: router-redis-url-embedded-credentials
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: '((?:rediss?(?:-cluster|-sentinel)?):\/\/)(?P<mask>[^\/@"\\]*:[^\/@"\\]+)(@)'
```

### Notes

- Scoped to the six Redis schemes (`redis`, `rediss`, `-cluster`/`-sentinel` variants) rather than any `user:pass@` substring, to avoid masking unrelated occurrences elsewhere in the config.
- The username may be empty, the password may not (`redis://:s3cr3t@host` is a normal Redis idiom pre-ACL) — masking requires a password but not a username, and a URL with no `@` has no credentials to mask.
- One pattern covers both surfaces: `redis://user:pass@` is byte-identical in escaped YAML and real JSON.
- **Overlaps a built-in redactor unevenly:** the built-in only fires on `redis://user:pass@host/<db>` (and then also masks the host and db index), so ours is the only cover for the common pathless form. A bundle with the host masked and one without it are both possible outputs, depending on whether `/<db>` was present — not a sign either rule failed.

## Redactor: `username`/`password` as separate fields

troubleshoot.sh's built-in redactors don't cover this shape, so it needs its own rules — one for `router.yaml`'s embedded JSON-escaped text, one for the `helm` collector's genuinely structured JSON.

### `router.yaml` (`configMap`/`clusterResources` output) — single-line `regex`

```yaml
- name: router-redis-username-password
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(username:\s*\\?"?)(?P<mask>[^"\\\n]+?)(\\?"?\\n)'
      - redactor: '(password:\s*\\?"?)(?P<mask>[^"\\\n]+?)(\\?"?\\n)'
```

### The `helm` collector's output — `yamlPath`

```yaml
- name: router-redis-username-password-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    yamlPath:
      - "*.releaseHistory.*.values.router.configuration.supergraph.query_planning.cache.redis.username"
      - "*.releaseHistory.*.values.router.configuration.supergraph.query_planning.cache.redis.password"
      - "*.releaseHistory.*.values.router.configuration.apq.router.cache.redis.username"
      - "*.releaseHistory.*.values.router.configuration.apq.router.cache.redis.password"
      - "*.releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.all.redis.username"
      - "*.releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.all.redis.password"
      - "*.releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.subgraphs.*.redis.username"
      - "*.releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.subgraphs.*.redis.password"
```

### Notes

- Eight paths: three cache configs, except entity caching splits into an `all` block plus a per-subgraph `subgraphs.*` map (per `specs/collection/base_spec.md`), times two fields each.

- The `router.yaml` regex is deliberately not scoped to the Redis blocks specifically. Since `username:`/`password:` are generic key names this pattern will also mask any other config field literally named `username`/`password` elsewhere in `router.yaml`, if one exists.

- The `helm` rule has the opposite risk: `yamlPath` can't over-mask, but if a path doesn't match the document's actual shape it masks nothing, silently. These paths assume the array root (`overview.md` → The `helm` collector's output) and the chart's `router.configuration` nesting — both confirmed from source and chart `v2.17.0`, not yet from a real bundle.

**Required before this is considered done:** collect against a router with (a) a URL-embedded credential in both the `user:pass@` and pathless `:pass@` forms, (b) `username`/`password` as separate fields, quoted in one cache block and unquoted in another, and (c) at least one Redis-backed cache left unconfigured. Confirm every credential is masked on both surfaces, the fields above survive, and the unconfigured cache's absence is attributable rather than mistaken for a rule that failed to match.

## What's deliberately left visible

`timeout`, `ttl`, `namespace`, `tls`, `required_to_start`, `reset_ttl`, and `pool_size` — none are secret material, and all are useful for diagnosing cache behavior.
