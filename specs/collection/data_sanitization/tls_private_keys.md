# TLS private keys

## The Problem

`tls.*` in `router.yaml` has three separate private-key locations, all PEM-encoded. Verified against `apollographql/router` at `v2.17.0`:

- **`tls.supergraph.key`** — the router's own server private key, backing the GraphQL endpoint's TLS listener. [`mod.rs#L1227-L1240`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/configuration/mod.rs#L1227)
- **`tls.subgraph.all.client_authentication.key`** and **`tls.subgraph.subgraphs.<name>.client_authentication.key`** — the router's client private key for mTLS to subgraphs. `.all` applies globally, `.subgraphs.<name>` overrides per subgraph. [`mod.rs#L1375-L1386`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/configuration/mod.rs#L1375), shape from [`subgraph.rs#L77-L89`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/configuration/subgraph.rs#L77)
- **`tls.connector.all.client_authentication.key`** and **`tls.connector.sources.<name>.client_authentication.key`** — same shape, for Apollo Connectors' outgoing mTLS. Note the field is `sources`, not `subgraphs`. [`connector.rs#L7-L20`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/configuration/connector.rs#L7)

**What's adjacent but not sensitive:** `tls.supergraph.certificate`/`.certificate_chain`, and `tls.{subgraph,connector}.*.certificate_authorities`. These are certificates and CA trust anchors — public by design, not private key material. See [What's deliberately left visible](#whats-deliberately-left-visible).

## Redactor: `router.yaml` (`configMap`/`clusterResources` output)

Unlike the fields in `jwt_and_auth_config.md` and `redis_credentials.md`, a PEM private key is self-delimiting — it always starts with a `-----BEGIN ... PRIVATE KEY-----` marker and ends with a matching `-----END ... PRIVATE KEY-----` marker, regardless of which of the three locations above it came from or what YAML key it sits under. **One rule covers all three locations**, unlike the field-specific rules elsewhere in this directory:

```yaml
- name: router-tls-private-keys
  removals:
    regex:
      - redactor: '(-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----)(?P<mask>.+?)(-----END (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----)'
```

**Notes:**

- **Deliberately has no `fileSelector` so it runs against every file in the bundle.**
- **Anchored on the PEM markers, not a YAML key or quoting.** A PEM block's real newlines become literal `\n` two-character sequences once `router.yaml` is captured as a JSON-escaped string, same as everywhere else in this directory — but since `.` in Go's `regexp` matches any byte except a real newline, and there are no real newline bytes left in a JSON-escaped single line, `.+?` matches straight through those literal `\n` sequences without needing to model them explicitly. This rule doesn't need the prefix/suffix YAML-structure modeling `jwt_and_auth_config.md`'s rules require.
- **`(?:RSA |EC |ENCRYPTED )?` covers the PEM header variants** rustls-based key loading in the router can encounter (PKCS8 `PRIVATE KEY`, PKCS1 `RSA PRIVATE KEY`, SEC1 `EC PRIVATE KEY`). RE2 has no backreferences, so the opening and closing markers aren't required to match the same variant — immaterial for redaction, since everything between the first BEGIN and the next END is masked regardless.
- **`.+?` (one or more, lazy), not `.*?`** — the mask must not be able to match the empty string (`overview.md` → Regex, single-line), and a real key body is never empty.
- **Only matches `PRIVATE KEY` markers**, not `CERTIFICATE` markers — certs use a textually distinct marker, so this rule can't accidentally reach into the non-sensitive fields listed above.

## Required before this is considered done

Configure a router with all three key locations populated with distinct test PEM keys (server, subgraph client auth, connector client auth), including at least one wrapped at a realistic line width (a real key's base64 body is typically wrapped every 64 characters). Confirm all three are fully masked — not just their first line — and that `certificate`/`certificate_chain`/`certificate_authorities` values survive untouched.

## What's deliberately left visible

Certificates and CA lists (`tls.supergraph.certificate`, `.certificate_chain`, `tls.{subgraph,connector}.*.certificate_authorities`) stay in the bundle. A certificate is public by design and knowing which CAs a deployment trusts, or what certificate the router presents, is diagnostically useful for exactly the kind of problem this tool exists to help with (a handshake failure, an expired cert, a subgraph rejecting the router's identity).
