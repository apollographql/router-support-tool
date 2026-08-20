# Subgraph URLs

`override_subgraph_url.<subgraphName>` in `router.yaml` is a plain string map (`HashMap<String, String>`), parsed via `http::Uri::from_str` (or a `unix://` socket path on Unix). Source: [`override_url.rs#L20-L32`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/override_url.rs#L20), verified at `v2.17.0`.

In the overwhelming majority of real deployments, these are internal service DNS names — `http://products.internal.svc.cluster.local:4001/graphql` — sensitive only as network topology, not as credential material. But `http::Uri` has no schema-level restriction against a userinfo component, so nothing prevents a customer from writing `http://user:pass@internal-host:4001/graphql`, and if one does, that's a literal credential sitting in the config.

**This doc does not have a settled position on which of two different things "sensitive" means here, and that's a real open question rather than an oversight:**

1. **Embedded credentials in the URL's userinfo component.** Unambiguously sensitive whenever present, rare in practice, and safe to always mask — masking a URL that never had credentials in it costs nothing, since there's nothing to mask.
2. **The URL/hostname itself, as internal topology.** Whether internal service names are "sensitive" is a customer-specific judgment call, not a fact — some customers consider their internal DNS structure sensitive, most don't, and it's directly useful for a support engineer diagnosing subgraph reachability. This is closer in shape to the schema/SDL decision (`schema_sdl.md`) — a customer preference, expressed as an opt-out — than to a redactor that should always run.

## Redactor: the unambiguous case

Always-on, defensive, single-line `regex` with a `mask` capture group (same reasoning as the other config-field redactors in this directory — `router.yaml` is embedded JSON-escaped text, so this is the only mechanism that reaches a specific substring inside it):

```yaml
- name: router-subgraph-url-embedded-credentials
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
      - "helm/*.json"
      - "helm/*/*.json"
  removals:
    regex:
      - redactor: '(:\/\/)(?P<mask>[^\/@"\\]+:[^\/@"\\]+)(@)'
```

**Draft, not verified — though less at risk than the other regex redactors in this directory.** This targets the `user:pass@` userinfo shape generically (not specific to `override_subgraph_url`'s own key name, since the pattern is the same wherever a URL with embedded credentials could appear in the config), and doesn't depend on YAML being in any particular style — the same robustness that makes it the pattern to imitate elsewhere in this directory (see `overview.md`) means the `helm/*.json` paths added above are actually likely to work here too, unlike the block-style-specific patterns in `jwt_and_auth_config.md`/`header_values.md`. **Required before this is considered done:** collect against a router with a credential-bearing `override_subgraph_url` entry and confirm it's masked in both the `configMap`/`clusterResources` output and the `helm` collector's output, and confirm the pattern doesn't false-positive on a URL that merely contains an `@` for an unrelated reason (unlikely in a URL authority position, but not verified).

## Open question, not yet decided: whether to also redact the hostname itself

If a future decision is that subgraph hostnames should be treated like schema/SDL — masked by default with a customer opt-in to reveal them, or vice versa — that's a different mechanism than the redactor above (closer to a full-value mask keyed on the `override_subgraph_url.*` path specifically, not a userinfo-only pattern) and a different chart-value decision (a `redaction.*` toggle, per `specs/deployment/v1/v1.md` → Chart values). This doc flags the question rather than answering it, per `CLAUDE.md`'s instruction to surface an undecided design question rather than resolve it inside an implementation doc.
