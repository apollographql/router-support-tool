# JWT and auth config

## The Problem

`authentication.*` in `router.yaml` is mostly reference metadata, not secret material. Two fields are the exceptions, and being in unrelated plugins, each needs its own redactor rule. Verified against `apollographql/router` at `v2.17.0`:

- **`authentication.router.jwt.jwks[].headers[]`** — headers sent when fetching the JWKS URL, e.g. an `Authorization` credential. [`mod.rs#L141-L159`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/authentication/mod.rs#L141)
- **`authentication.subgraph.all.aws_sig_v4.hardcoded.{access_key_id, secret_access_key}`** (and per-subgraph, `authentication.subgraph.subgraphs.<name>...`) — a hardcoded AWS key pair. [`subgraph.rs#L40-L55, #L201-L219`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/authentication/subgraph.rs#L40)

## Redactor: `router.yaml` (`configMap`/`clusterResources` output)

Single-line `regex` with a `mask` capture group:

```yaml
- name: router-jwt-jwks-fetch-headers
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(name:\s*\\?"?[^"\\\n]*\\?"?\\n\s*value:\s*\\?"?)(?P<mask>[^"\\\n]+)(\\?"?)'
      - redactor: '(headers:\s*\[\s*\{(?:[^}\\]|\\")*?value:\s*\\?"?)(?P<mask>[^",}\\]+)(\\?"?)'
- name: router-subgraph-aws-sigv4-hardcoded
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(secret_access_key:\s*\\?"?)(?P<mask>[^"\\\n]+?)(\\?"?\\n)'
      - redactor: '(access_key_id:\s*\\?"?)(?P<mask>[^"\\\n]+?)(\\?"?\\n)'
```

**Notes on the JWKS rule:**

- **Matches on the `{name, value}` shape, not the header's name** — so it catches any JWKS-fetch header (`X-API-Key`, `X-Vault-Token`, not just `Authorization`). The name stays in the captured prefix and survives; only the value is masked.
- **Not scoped to the `jwks` block** — RE2 has no lookbehind, so it can't anchor on a parent key without missing later entries in the list. As a result it also masks any other `name:`/`value:` pair in the collected config, including unrelated ones swept up by `clusterResources`. Accepted trade: keys stay readable, double-masking is idempotent.
- **Block style covers every entry, flow style covers only the first**, same RE2 limitation as `header_values.md`. A flow list past one entry is left unmasked.

## Redactor: the `helm` collector's output

```yaml
- name: router-jwt-jwks-fetch-headers-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    yamlPath:
      - "*.releaseHistory.*.values.router.configuration.authentication.router.jwt.jwks.*.headers.*.value"
- name: router-subgraph-aws-sigv4-hardcoded-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: '("?secret_access_key"?:\s*"?)(?P<mask>[^",\n]+)("?)'
      - redactor: '("?access_key_id"?:\s*"?)(?P<mask>[^",\n]+)("?)'
    yamlPath:
      - "*.releaseHistory.*.values.router.configuration.authentication.subgraph.all.aws_sig_v4.hardcoded.access_key_id"
      - "*.releaseHistory.*.values.router.configuration.authentication.subgraph.all.aws_sig_v4.hardcoded.secret_access_key"
      - "*.releaseHistory.*.values.router.configuration.authentication.subgraph.subgraphs.*.aws_sig_v4.hardcoded.access_key_id"
      - "*.releaseHistory.*.values.router.configuration.authentication.subgraph.subgraphs.*.aws_sig_v4.hardcoded.secret_access_key"
```

- **JWKS headers** use `yamlPath` on `helm` (exact path, order-independent) and the name-agnostic regex above on the embedded surface — see the notes above for what that trade costs.
- **AWS keys use both `yamlPath` and regex.** `yamlPath` targets the four known locations precisely; the regex is a safety net, since `secret_access_key`/`access_key_id` are self-identifying enough to also catch a key pair placed outside the documented path (e.g. `extraEnvVars`). Missing a plaintext AWS key is worse than over-masking.

**Required before this is considered done:** configure two non-`Authorization` JWKS fetch headers (one block-style, one single-entry flow, one quoted), a hardcoded `aws_sig_v4` key pair, and a `default_chain` block. On both surfaces, confirm all of them are masked while header names, JWKS URL, issuer, algorithms, and the `default_chain` profile survive. Also confirm the multi-entry flow-list gap: in a two-entry flow list, only the first value is masked.

## What's deliberately left visible

Everything else in `authentication.*` — the JWKS URL itself, header names, issuer/audience lists, algorithms — is left in the bundle on purpose: none of it is secret material, and it's what a support engineer needs to check when a customer reports JWT validation failures (wrong issuer, wrong audience, unreachable JWKS endpoint).

The `aws_sig_v4.default_chain` variant is also left untouched — unlike `hardcoded`, it only references a credential provider/profile (env vars, instance metadata, an AWS profile name) and holds no literal secret in the YAML.
