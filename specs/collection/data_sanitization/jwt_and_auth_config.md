# JWT and auth config

`authentication.*` in `router.yaml` is mostly reference metadata, not secret material — but it has two real exceptions, and the redactor has to hit those specifically rather than the whole block, because the rest of it is genuinely useful for diagnosis as-is.

Verified against `apollographql/router` at `v2.17.0`.

## What's in the block, and which parts are actually sensitive

| Field | What it holds | Sensitive? |
| --- | --- | --- |
| `authentication.router.jwt.jwks[].url` | The URL the router fetches signing keys from | No — a fetch target, not a secret. Confirms which JWKS source is configured, which is exactly what a support engineer needs to check first. |
| `authentication.router.jwt.jwks[].header_name`, `.header_value_prefix`, `.ignore_other_prefixes` | Where the router looks for the token, and what prefix it expects | No — config shape, not a value |
| `authentication.router.jwt.jwks[].issuers`, `.audiences`, `.algorithms`, `sources[]`, `on_error` | Validation policy | No |
| **`authentication.router.jwt.jwks[].headers[]`** | Arbitrary `{name, value}` HTTP headers sent when the router fetches that JWKS URL | **Yes.** If an issuer requires an `Authorization` header to serve its JWKS, that credential is a literal value in the YAML. Source: [`mod.rs#L141-L159`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/authentication/mod.rs#L141) |
| **`authentication.subgraph.all.aws_sig_v4.hardcoded.{access_key_id, secret_access_key}`** (and the per-subgraph equivalent, `authentication.subgraph.subgraphs.<name>...`) | A hardcoded AWS access key pair used to sign subgraph requests | **Yes — a plaintext AWS secret.** Distinct from the `default_chain` variant, which only references a credential provider/profile and holds no literal. Source: [`subgraph.rs#L40-L55`, `#L201-L219`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/authentication/subgraph.rs#L40) |

The JWKS `headers[]` field and the `aws_sig_v4.hardcoded` block are structurally unrelated (different plugins, different nesting), so this needs two separate redactor rules, not one pattern that happens to cover both.

## Redactor

Both rules use single-line `regex` with a `mask` capture group, per `overview.md`'s reasoning: `router.yaml` is embedded as a JSON-escaped string inside the collector output, so this is the only mechanism that can reach a specific field inside it without removing the whole config.

```yaml
- name: router-jwt-jwks-fetch-headers
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: 'name:\s*"?[Aa]uthorization"?\\n\s*value:\s*"?(?P<mask>[^"\\\n]*?)"?'
- name: router-subgraph-aws-sigv4-hardcoded
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: 'secret_access_key:\s*"?(?P<mask>[^"\\\n]*?)"?\\n'
      - redactor: 'access_key_id:\s*"?(?P<mask>[^"\\\n]*?)"?\\n'
```

**These patterns target block-style YAML, not a JSON-object or flow-map shape — an earlier draft got this wrong and it's worth recording why.** `data["configuration.yaml"]` holds the ConfigMap value's literal text, exactly as authored — JSON-escaping turns a real newline into the two literal characters `\n` and a real quote into `\"`, but it does not restructure block-style YAML (`name: Authorization` on one line, `value: "..."` on the next, each indented) into a single-line JSON object. A pattern like `\"name\":\"Authorization\",\"value\":\"...\"` assumes a shape nothing in this pipeline produces. The corrected patterns above match the `name:`/`value:` keys as separate, `\n`-separated lines — the shape `router.yaml` actually takes — with the value optionally quoted, since YAML doesn't require quoting a scalar.

**The `helm/` paths cover a second leak this directory missed initially.** `specs/collection/base_spec.md` → `router.yaml` capture runs the `helm` collector (`collectValues: true`) unconditionally alongside `configMap` — so the Helm values layer, where a customer would have originally set these fields before they're templated into the rendered config, is a second copy of the same secrets. **This is very likely a third distinct serialization, not the same block-style shape the two patterns above target** — `helm`'s own output format for `collectValues: true` was not verified during the research behind this directory, so treat the `helm/*.json` fileSelector entries above as scoping-only for now: they ensure the file is in scope for *some* redactor, not evidence that either pattern above will actually match content in that format.

**Still drafts, and still require a live bundle before being trusted** — not because the escaping depth might be off (that was the wrong framing for the `router.yaml` case), but because the exact indentation, key ordering (`name` before `value` is assumed, matching idiomatic authoring, but not guaranteed), whether `helm`'s output needs its own pattern entirely, and this file's `fileSelector` globs (provisional pending confirmation from `specs/collection/output.md`) all need confirming against real collected output. **Required before this is considered done:** run collection against a router configured with both a JWKS `Authorization` header and a hardcoded AWS SigV4 credential, get one real bundle, and read the actual escaped text of both the `configMap`/`clusterResources` output and the `helm` collector's output before assuming either pattern matches either one — this belongs in the redaction section of the verification matrix (`CLAUDE.md` → Testing and verification), not just a code read.

## What's deliberately left visible

Everything else in `authentication.*` — the JWKS URL itself, header names, issuer/audience lists, algorithms — is left in the bundle on purpose. It's exactly what a support engineer checks first when a customer reports JWT validation failures (wrong issuer, wrong audience, unreachable JWKS endpoint), and masking it would trade that diagnostic value for no actual security benefit, since none of it is secret material.
