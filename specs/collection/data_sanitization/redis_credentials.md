# Redis credentials in cache config

## The Problem

The base spec collects the Redis config block that already lives inside `router.yaml` itself, and that configuration can carry a literal credential — either embedded in a connection URL, or as a separate field. The `helm`/`configMap` collectors capture `router.yaml` in full for unrelated reasons (they're how the base spec gets the router's config at all), and per `specs/collection/base_spec.md`'s own Redis section, "whichever of these three [cache configs] the customer has enabled rides along in the same `helm`/`configMap` capture as the rest of `router.yaml`."

The router's three Redis-backed caches (query-plan, APQ, entity caching — see `specs/collection/base_spec.md` → Where Redis configuration appears in `router.yaml`) share the same underlying config shape: `urls`, `username`, `password`, `timeout`, `ttl`, `namespace`, `tls`, `required_to_start`, `reset_ttl`, `pool_size`. `username`/`password` exist as separate fields specifically so a customer *can* keep the connection string itself credential-free — but nothing in the router enforces that, and the two are not mutually exclusive in a way that would make the redundant case impossible.

Verified against `apollographql/router` at `v2.17.0`.

### Why it reaches the bundle

The `router.yaml` capture mechanism (`helm` collector, `configMap` collector — `specs/collection/base_spec.md` → `router.yaml` capture) captures the config as written in full. A customer who embeds `redis://user:password@host:6379` in any of the three cache configs' `urls` field has that literal credential collected into the bundle the ordinary way, with no special mechanism required to leak it — and the same is true, identically, for a customer who instead sets `username`/`password` as separate fields. Neither capture mechanism is redaction-aware on its own; both forms are collected exactly as written.

## Redactor: embedded URL credentials

Single-line `regex` with a `mask` capture group, for the same reason given in `overview.md` (`router.yaml` is embedded JSON-escaped text) and `subgraph_urls.md` (a credential-shaped substring match, not anchored to a specific YAML key, is the most robust pattern in this directory because it doesn't depend on serialization style):

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
      - redactor: '(redis(s)?(-cluster|-sentinel)?:\/\/)(?P<mask>[^\/@"\\]+:[^\/@"\\]+)(@)'
```
**Notes:**

- This targets the `redis://`/`rediss://`/`redis-cluster://`/`redis-sentinel://` schemes specifically (confirmed as the valid scheme set from the same file's test cases), rather than reusing `subgraph_urls.md`'s scheme-agnostic pattern verbatim — a Redis URL's userinfo is unambiguously a credential (unlike a generic subgraph URL, where userinfo is rare and defensive), so scoping to Redis schemes avoids masking unrelated `user:pass@` occurrences elsewhere in the config that this doc has no basis to judge.

- **One pattern covers both file shapes** - This pattern never relies on JSON-escaping sequences — a `redis://user:pass@` substring looks the same whether it's sitting inside JSON-escaped block-style YAML (`router.yaml` via `configMap`/`clusterResources`) or real, unescaped JSON (the `helm` collector's output — confirmed structure, per `overview.md` → The `helm` collector's output: genuine `json.MarshalIndent` output, not a string blob). So the `helm/*.json` paths above don't need a second, format-specific rule the way `jwt_and_auth_config.md` and `header_values.md` did.

- **Required before this is considered done:** Collect against a router with a credential-bearing Redis `urls` entry in at least one of the three cache configs, and confirm it's masked in both the `configMap`/`clusterResources` output and the `helm` collector's output.

## Redactor: `username`/`password` as separate fields

Confirmed from source that troubleshoot.sh's built-in redactors don't cover this shape (see below), so it needs its own rules — one for `router.yaml`'s embedded JSON-escaped text, one for the `helm` collector's genuinely structured JSON, following the same split established for the AWS SigV4 case in `jwt_and_auth_config.md`.

**`router.yaml` (`configMap`/`clusterResources` output) — single-line `regex`:**

```yaml
- name: router-redis-username-password
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: 'username:\s*"?(?P<mask>[^"\\\n]*?)"?\\n'
      - redactor: 'password:\s*"?(?P<mask>[^"\\\n]*?)"?\\n'
```

**The `helm` collector's output — `yamlPath`, precise rather than key-name matching:** unlike the router.yaml case, `helm/*.json` is genuinely structured JSON, so each cache config's exact path can be targeted directly rather than matching the generic key name `username`/`password` wherever it appears. Paths come from `specs/collection/base_spec.md`'s already-verified Redis config-path table:

```yaml
- name: router-redis-username-password-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    yamlPath:
      - "releaseHistory.*.values.router.configuration.supergraph.query_planning.cache.redis.username"
      - "releaseHistory.*.values.router.configuration.supergraph.query_planning.cache.redis.password"
      - "releaseHistory.*.values.router.configuration.apq.router.cache.redis.username"
      - "releaseHistory.*.values.router.configuration.apq.router.cache.redis.password"
      - "releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.all.redis.username"
      - "releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.all.redis.password"
      - "releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.subgraphs.*.redis.username"
      - "releaseHistory.*.values.router.configuration.preview_entity_cache.subgraph.subgraphs.*.redis.password"
```

Eight paths: three cache configs, except entity caching splits into an `all` block plus a per-subgraph `subgraphs.*` map (per `specs/collection/base_spec.md`), times two fields each.

**Notes:**

- **The `router.yaml` regex is deliberately not scoped to the Redis blocks specifically, and that's an accepted tradeoff, not an oversight.** `username:`/`password:` are generic key names — this pattern will also mask any other config field literally named `username`/`password` elsewhere in `router.yaml`, if one exists.
- **The `helm` output rule doesn't have that problem** — `yamlPath` targets the exact three cache configs by path, so it can't mask anything outside them. Its risk is the opposite kind: if `router.configuration`'s nesting or `releaseHistory`'s array shape doesn't match what's assumed (same caveat as `header_values.md`'s helm-output rule), the path simply doesn't match anything, silently.
- **Required before this is considered done:** Collect against a router with `username`/`password` set as separate fields in at least one cache config, and confirm both rules mask them correctly — the `router.yaml` regex in the `configMap`/`clusterResources` output, and the `yamlPath` rules in the `helm` collector's output, including verifying the assumed `releaseHistory`/`router.configuration` nesting actually holds.

## What's deliberately left visible

`timeout`, `ttl`, `namespace`, `tls`, `required_to_start`, `reset_ttl`, and `pool_size` are left visible in every case — none of them are secret material, and they're useful for diagnosing cache behavior (TTL misconfiguration, pool sizing, whether TLS is enabled).
