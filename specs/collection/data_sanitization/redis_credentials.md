# Redis credentials embedded in cache URLs

**This is unrelated to troubleshoot.sh's `redis` collector, which the base spec deliberately does not use** (`specs/collection/base_spec.md` → Redis health: not collected) — that decision is about not actively connecting to Redis to check connectivity or version. This doc is about something the base spec collects regardless of that decision: the Redis config block that already lives *inside* `router.yaml` itself. The `helm`/`configMap` collectors capture `router.yaml` in full for unrelated reasons (they're how the base spec gets the router's config at all), and per `specs/collection/base_spec.md`'s own Redis section, "whichever of these three [cache configs] the customer has enabled rides along in the same `helm`/`configMap` capture as the rest of `router.yaml`." So even though the tool never talks to Redis, it still collects the router's Redis *configuration* — and that configuration can carry a literal credential.

The router's three Redis-backed caches (query-plan, APQ, entity caching — see `specs/collection/base_spec.md` → Where Redis configuration appears in `router.yaml`) share the same underlying config shape: `urls`, `username`, `password`, `timeout`, `ttl`, `namespace`, `tls`, `required_to_start`, `reset_ttl`, `pool_size`. `username`/`password` exist as separate fields specifically so a customer *can* keep the connection string itself credential-free — but nothing in the router enforces that, and the two are not mutually exclusive in a way that would make the redundant case impossible.

Verified against `apollographql/router` at `v2.17.0`.

## Why this is a real gap, not a hypothetical

`RedisCacheStorage::new` parses `config.urls` into a Redis client config first, via `RedisConfig::from_url` — which resolves any `user:pass@host` userinfo embedded directly in the URL — and only *then* applies `config.username`/`config.password` on top, overwriting whatever the URL supplied:

```rust
let mut client_config = RedisConfig::from_url(url.as_str())...
if let Some(username) = config.username {
    client_config.username = Some(username);
}
if let Some(password) = config.password {
    client_config.password = Some(password);
}
```

Source: [`cache/redis.rs#L291-L302`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/cache/redis.rs#L291)

So the separate fields **take precedence over**, rather than **replace**, credentials embedded in `urls` — a customer who sets `username`/`password` and leaves `urls` credential-free gets exactly the same behavior as one who embeds `redis://user:password@host:6379` directly and never touches `username`/`password` at all. Both are fully supported, equally live configurations. The router's own docs and this project's redaction posture can't assume the safer of the two — a customer choosing the embedded form is not doing anything unsupported or discouraged, just less careful.

## Why it reaches the bundle

Neither `router.yaml` capture mechanism (`helm` collector, `configMap` collector — `specs/collection/base_spec.md` → `router.yaml` capture) is redaction-aware on its own; both capture the config as written, in full. A customer who embeds `redis://user:password@host:6379` in any of the three cache configs' `urls` field has that literal credential collected into the bundle the ordinary way, with no special mechanism required to leak it — this isn't an edge case in how collection works, it's the base case, no different from any other literal value in `router.yaml`.

## Redactor

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

This targets the `redis://`/`rediss://`/`redis-cluster://`/`redis-sentinel://` schemes specifically (confirmed as the valid scheme set from the same file's test cases), rather than reusing `subgraph_urls.md`'s scheme-agnostic pattern verbatim — a Redis URL's userinfo is unambiguously a credential (unlike a generic subgraph URL, where userinfo is rare and defensive), so scoping to Redis schemes avoids masking unrelated `user:pass@` occurrences elsewhere in the config that this doc has no basis to judge.

**Draft, not verified — same status as every other redactor in this directory.** The `helm/*.json` paths are scoping-only, not a confirmed match, for the reason given in `jwt_and_auth_config.md`: `collectValues: true`'s output format wasn't verified during this directory's research and is unlikely to match the JSON-escaped block-YAML shape this pattern otherwise targets. **Required before this is considered done:** collect against a router with a credential-bearing Redis `urls` entry in at least one of the three cache configs, and confirm it's masked in both the `configMap`/`clusterResources` output and the `helm` collector's output.

## What's deliberately left visible

`username` and `password` as separate fields are visible when set, which is unavoidable — they're exactly the shape this redactor doesn't target, since a customer using them correctly has already kept the credential out of `urls`. This is a real, accepted gap in coverage, not an oversight: this directory has no mechanism to redact `username:`/`password:` fields under the three Redis cache config paths without either (a) writing three more block-style key/value patterns, duplicating the risk profile already flagged for `header_values.md` and `jwt_and_auth_config.md` (block-vs-flow-style ambiguity, silent failure on a wrong assumption), or (b) reusing troubleshoot.sh's own built-in redactors, which already match generic `password`/`user` env-var-style keys (per `overview.md` → Built-in redactors) and may already catch this case without any custom rule at all — worth checking against a real bundle before writing new patterns that might duplicate coverage the built-ins already provide.
