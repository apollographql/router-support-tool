# JWT and auth config

## The Problem
`authentication.*` in `router.yaml` is mostly reference metadata, not secret material — but it has two real exceptions, and the redactor has to hit those specifically rather than the whole block, because the rest of it is genuinely useful for diagnosis as-is.

Verified against `apollographql/router` at `v2.17.0`.

### What's in the block and which parts are actually sensitive

| Field | What it holds | Sensitive? |
| --- | --- | --- |
| `authentication.router.jwt.jwks[].url` | The URL the router fetches signing keys from | No — a fetch target, not a secret. Confirms which JWKS source is configured, which is exactly what a support engineer needs to check first. |
| `authentication.router.jwt.jwks[].header_name`, `.header_value_prefix`, `.ignore_other_prefixes` | Where the router looks for the token, and what prefix it expects | No — config shape, not a value |
| `authentication.router.jwt.jwks[].issuers`, `.audiences`, `.algorithms`, `sources[]`, `on_error` | Validation policy | No |
| **`authentication.router.jwt.jwks[].headers[]`** | Arbitrary `{name, value}` HTTP headers sent when the router fetches that JWKS URL | **Yes.** If an issuer requires an `Authorization` header to serve its JWKS, that credential is a literal value in the YAML. Source: [`mod.rs#L141-L159`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/authentication/mod.rs#L141) |
| **`authentication.subgraph.all.aws_sig_v4.hardcoded.{access_key_id, secret_access_key}`** (and the per-subgraph equivalent, `authentication.subgraph.subgraphs.<name>...`) | A hardcoded AWS access key pair used to sign subgraph requests | **Yes — a plaintext AWS secret.** Distinct from the `default_chain` variant, which only references a credential provider/profile and holds no literal. Source: [`subgraph.rs#L40-L55`, `#L201-L219`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/authentication/subgraph.rs#L40) |

The JWKS `headers[]` field and the `aws_sig_v4.hardcoded` block are structurally unrelated (different plugins, different nesting), so this needs two separate redactor rules, not one pattern that happens to cover both.

## Redactor: `router.yaml` (`configMap`/`clusterResources` output)

Single-line `regex` with a `mask` capture group, per `overview.md`'s reasoning: `router.yaml` is embedded as a JSON-escaped string inside the collector output, so this is the only mechanism that can reach a specific field inside it without removing the whole config.

```yaml
- name: router-jwt-jwks-fetch-headers
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: 'name:\s*"?[Aa]uthorization"?\\n\s*value:\s*"?(?P<mask>[^"\\\n]*?)"?'
- name: router-subgraph-aws-sigv4-hardcoded
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: 'secret_access_key:\s*"?(?P<mask>[^"\\\n]*?)"?\\n'
      - redactor: 'access_key_id:\s*"?(?P<mask>[^"\\\n]*?)"?\\n'
```
**Notes:**
- **These patterns target block-style YAML, not a JSON-object or flow-map shape — an earlier draft got this wrong and it's worth recording why.** `data["configuration.yaml"]` holds the ConfigMap value's literal text, exactly as authored — JSON-escaping turns a real newline into the two literal characters `\n` and a real quote into `\"`, but it does not restructure block-style YAML (`name: Authorization` on one line, `value: "..."` on the next, each indented) into a single-line JSON object. A pattern like `\"name\":\"Authorization\",\"value\":\"...\"` assumes a shape nothing in this pipeline produces. The patterns above match the `name:`/`value:` keys as separate, `\n`-separated lines — the shape `router.yaml` actually takes — with the value optionally quoted, since YAML doesn't require quoting a scalar.

- **Required before this is considered done:** collect against a router configured with a hardcoded JWKS `Authorization` header, and a separate collection with a hardcoded AWS SigV4 credential, and confirm each pattern matches its corresponding case in real collected output.

## Redactor: the `helm` collector's output

`specs/collection/base_spec.md` → `router.yaml` capture runs the `helm` collector (`collectValues: true`) unconditionally alongside `configMap` — so the Helm values layer, where a customer would have originally set these fields before they're templated into the rendered config, is a second copy of the same secrets. Per `overview.md` → The `helm` collector's output is a different shape entirely, this file is genuine pretty-printed JSON (`json.MarshalIndent`, real newlines, tab indentation) — not JSON-escaped text embedded in a string — so it needs its own rules, not the two patterns above:

```yaml
- name: router-jwt-jwks-fetch-headers-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - selector: '"name":\s*"[Aa]uthorization"'
        redactor: '"value":\s*"(?P<mask>[^"]*)"'
- name: router-subgraph-aws-sigv4-hardcoded-helm
  fileSelector:
    files:
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: '"secret_access_key":\s*"(?P<mask>[^"]*)"'
      - redactor: '"access_key_id":\s*"(?P<mask>[^"]*)"'
```
**Notes:**
- The JWKS-headers rule uses the **two-line** mechanism (`selector` + `redactor`) rather than single-line, because `{name, value}` in a real Go-marshaled JSON map renders as two separate, adjacent lines — `"name": "Authorization",` then `"value": "secret"` below it — exactly what that mechanism exists for. The AWS SigV4 rule stays single-line, since `secret_access_key`/`access_key_id` are self-identifying keys directly adjacent to their own values on one line; it's simpler than the `router.yaml` version above precisely because there's no JSON-escaping to account for here — the quotes are real.

- **Required before this is considered done:** collect against a router configured with a hardcoded JWKS `Authorization` header, and a separate collection with a hardcoded AWS SigV4 credential, and confirm each rule matches its corresponding case in the `helm/*.json` output specifically.

## What's deliberately left visible

Everything else in `authentication.*` — the JWKS URL itself, header names, issuer/audience lists, algorithms — is left in the bundle on purpose: it's what a support engineer needs to check when a customer reports JWT validation failures (wrong issuer, wrong audience, unreachable JWKS endpoint), and masking it would trade that diagnostic value for no actual security benefit, since none of it is secret material.
