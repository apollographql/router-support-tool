# Redis credentials in cache config

## The Problem

`router.yaml`'s Redis cache config can carry a literal credential two ways: embedded in a connection URL (`redis://user:pass@host:6379`), or as separate `username`/`password` fields. Nothing in the router requires one over the other, and both can be set at once.

The `configMap` collector captures `router.yaml` as written, so either form is collected into the bundle. This applies to all three Redis-backed caches — query-plan, APQ, and entity caching — which share the same config shape. Verified against `apollographql/router` at `v2.17.0`.

## Redactor: embedded URL credentials

Single-line `regex` with a `mask` capture group:

```yaml
- name: router-redis-url-embedded-credentials
  removals:
    regex:
      - redactor: '((?:rediss?(?:-cluster|-sentinel)?):\/\/)(?P<mask>[^\/@"\\]*:[^\/@"\\]+)(@)'
```

### Notes

- Scoped to the six Redis schemes (`redis`, `rediss`, `-cluster`/`-sentinel` variants) rather than any `user:pass@` substring, to avoid masking unrelated occurrences elsewhere in the config.
- The username may be empty, the password may not (`redis://:s3cr3t@host` is a normal Redis idiom pre-ACL) — masking requires a password but not a username, and a URL with no `@` has no credentials to mask.
- **Overlaps a built-in redactor unevenly:** the built-in only fires on `redis://user:pass@host/<db>` (and then also masks the host and db index), so ours is the only cover for the common pathless form. A bundle with the host masked and one without it are both possible outputs, depending on whether `/<db>` was present — not a sign either rule failed.
- **Deliberately has no `fileSelector` so it runs against every file in the bundle:** Going unscoped reaches surfaces like `cluster-resources/custom-resources/*.json` that no enumerated workload-kind list anticipated, catching a Redis connection string wherever `clusterResources` happens to collect one, not just the pod-spec kinds this repo thought to list.
- **Risk of over-redaction**: For example, a CRD schema's example field with a fully-credentialed sample string gets masked the same as a real credential.

## Redactor: `username`/`password` as separate fields

troubleshoot.sh's built-in redactors don't cover this shape, so it needs its own rule, against `router.yaml`'s embedded JSON-escaped text:

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

### Notes

- This pattern is deliberately not scoped to the Redis blocks specifically. Since `username:`/`password:` are generic key names it will also mask any other config field literally named `username`/`password` elsewhere in `router.yaml`, if one exists.

**Required before this is considered done:** collect against a router with (a) a URL-embedded credential in both the `user:pass@` and pathless `:pass@` forms, (b) `username`/`password` as separate fields, quoted in one cache block and unquoted in another, and (c) at least one Redis-backed cache left unconfigured. Confirm every credential is masked, the fields above survive, and the unconfigured cache's absence is attributable rather than mistaken for a rule that failed to match.

## What's deliberately left visible

`timeout`, `ttl`, `namespace`, `tls`, `required_to_start`, `reset_ttl`, and `pool_size` — none are secret material, and all are useful for diagnosing cache behavior.
