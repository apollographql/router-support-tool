# Subgraph URLs

## The Problem

`override_subgraph_url.<subgraphName>` in `router.yaml` is a plain string map (`HashMap<String, String>`), parsed via `http::Uri::from_str` (or a `unix://` socket path on Unix). Source: [`override_url.rs#L20-L32`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/override_url.rs#L20), verified at `v2.17.0`.

In the overwhelming majority of real deployments, these are internal service DNS names — `http://products.internal.svc.cluster.local:4001/graphql` — sensitive only as network topology, not as credential material. But `http::Uri` has no schema-level restriction against a userinfo component, so nothing prevents a customer from writing `http://user:pass@internal-host:4001/graphql`, and if one does, that's a literal credential sitting in the config.

### Two different things "sensitive" could mean here — only one needs a redactor

1. **Embedded credentials in the URL's userinfo component.** Unambiguously sensitive whenever present, rare in practice, and safe to always mask — masking a URL that never had credentials in it costs nothing, since there's nothing to mask. Addressed below.
2. **The URL/hostname itself, as internal topology.** Decided: this does not need masking or an opt-out, and not because it's judged harmless in isolation — `clusterResources` already collects Service objects unconditionally (`cluster-resources/services/<namespace>.json`, per `specs/collection/output.md`), alongside Deployments and Pods. A Kubernetes Service named `products` in namespace `default` *is* the DNS name `products.default.svc.cluster.local` — so the internal topology a masked subgraph URL would protect is already fully exposed elsewhere in every bundle this tool produces, regardless of what this file does. Masking it here would trade real diagnostic value (subgraph reachability, which is exactly what a support engineer checks this field for) for no actual privacy benefit, since the same information is already sitting in `cluster-resources/`. See "What's deliberately left visible" below.

## Redactor: embedded URL credentials

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

**Notes:**

- This targets the `user:pass@` userinfo shape generically (not specific to `override_subgraph_url`'s own key name, since the pattern is the same wherever a URL with embedded credentials could appear in the config), and doesn't depend on any particular serialization at all — it never relies on JSON-escaping sequences the way the `router.yaml`-targeting patterns elsewhere in this directory do.
- **One pattern covers both file shapes:** Per `overview.md` → The `helm` collector's output, `helm/*.json` is real, unescaped JSON, and this pattern needs no changes to match there too — a `://user:pass@` substring looks identical whether it's sitting inside JSON-escaped block-style YAML or a plain JSON string value. This is the one redactor in this directory that didn't need a second, format-specific rule for the `helm/*.json` paths.
- **Required before this is considered done:** collect against a router with a credential-bearing `override_subgraph_url` entry and confirm it's masked in both the `configMap`/`clusterResources` output and the `helm` collector's output, and confirm the pattern doesn't false-positive on a URL that merely contains an `@` for an unrelated reason (unlikely in a URL authority position, but not verified).

## What's deliberately left visible

The URL/hostname itself — everything outside a userinfo component, which is the common case — is left visible, deliberately and not just by default. Per the decision above, masking it would provide no privacy benefit that `clusterResources`'s unconditional collection of Services, Deployments, and Pods doesn't already provide, and it would cost the diagnostic value a support engineer needs when checking subgraph reachability. No opt-out or opt-in toggle is proposed for this field, unlike schema/SDL — the two cases looked similar at first, but they aren't: schema content reveals business logic and structure that lives nowhere else in the bundle, while a subgraph hostname reveals nothing that `cluster-resources/` doesn't already.
