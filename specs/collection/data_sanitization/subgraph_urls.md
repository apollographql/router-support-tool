# Subgraph URLs

## The Problem

`override_subgraph_url.<subgraphName>` in `router.yaml` is a plain string map parsed via `http::Uri::from_str` ([`override_url.rs#L20-L32`](https://github.com/apollographql/router/blob/v2.17.0/apollo-router/src/plugins/override_url.rs#L20), verified at `v2.17.0`). The values are network addresses, usually internal service DNS names, sometimes external hosts, and nothing prevents a userinfo component (`http://user:pass@internal-host:4001/graphql`) from being included as well.

## We redact the whole URL, not just the credentials

A subgraph URL is masked in full because the address itself is the disclosure, and the credential is the rarer case.

- The host is internal topology. `http://products.checkout-prod.svc.cluster.local:4001/graphql` names a namespace, a service, and a port.

- An external host can reveal a business relationship.

- Support does not need the address to use the field. What is diagnostically useful is *that* an override exists and *which* subgraph it applies to — and the subgraph name survives in the schema. A customer can supply the URL directly if a specific question turns on it.

Rejected alternative: mask only the userinfo, leaving the address.

## Redactor: `router.yaml` (`configMap`/`clusterResources` output)

This surface masks the **whole block**, keys included — RE2 has no lookbehind, so no pattern can scope itself to entries under `override_subgraph_url:` specifically without either missing later entries or over-matching unrelated ones.

```yaml
- name: router-subgraph-url
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(override_subgraph_url:)(?P<mask>(?:\\n\s+(?:[^\\]|\\")+)+)'
```

**Consequence:** subgraph *names* don't survive this surface — the pattern can only mask the block wholesale, a side effect of the RE2 constraint. They're only preserved via the schema (below), when one is collected.

## Redactor: subgraph URLs in the supergraph schema

Every supergraph schema carries the canonical URL of every subgraph in a `@join__graph` directive, which is federation spec, not a customer choice:

```graphql
directive @join__graph(name: String!, url: String!) on ENUM_VALUE

enum join__Graph {
  ACCOUNTS @join__graph(name: "accounts", url: "https://accounts.demo.dev/")
}
```

That schema is collected whenever the customer sets `.Values.supergraphFile` — it lands in the `<release>-supergraph` ConfigMap and is swept up by `clusterResources` (`specs/collection/base_spec.md` → Schema collection).

```yaml
- name: router-subgraph-url-schema
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
      - "configmaps/*/*.json"
  removals:
    regex:
      - redactor: '(@join__graph\([^)]*url:\s*\\?")(?P<mask>[^"\\]*)(\\?")'
      - redactor: '(baseURL:\s*\\?")(?P<mask>[^"\\]*)(\\?")'
```

**Notes:**

- Anchors on `@join__graph(` rather than a bare `url:`, so it doesn't also mask `@link(url: …)` (the federation spec version) or a customer's own `url: String` field.
- Assumes the SDL is collected as one physical line inside the ConfigMap JSON; it would not match if the schema were ever collected as a standalone `.graphql` file.
- The second pattern anchors on `baseURL` directly to reach Apollo Connectors' external API addresses (`@source(http: { baseURL: … })`, nested inside `@join__directive`) — a connector base URL is usually third-party, making it the disclosure most likely to name a business relationship.
- Managed-federation customers are unaffected: their schema comes from Uplink at runtime and never lands in a ConfigMap.

**Required before this is considered done:** collect with (a) `override_subgraph_url` set for two subgraphs, one quoted and one not, followed by a top-level key, (b) a `supergraphFile` schema carrying `@join__graph` URLs and a connector `baseURL`, and (c) a `@link` directive. Confirm every address is masked, and subgraph names and the `@link` URL survive.

The key after the block is deliberately not asserted as surviving — see `overview.md` → [A built-in redactor can over-redact past a masked URL](overview.md#a-built-in-redactor-can-over-redact-past-a-masked-url).

## What's deliberately left visible

- **Subgraph names**, everywhere they can be kept — `@join__graph(name: …)` and a connector's `graphs` argument. Knowing which subgraphs exist, and which one an override applies to, is what makes the field useful to support. The one exception is the `override_subgraph_url` block itself, for the RE2 reason above; the same names survive via the schema when one is collected.
- **`@link(url: …)`**, which pins the federation spec version rather than naming a customer host.
- **A connector's `name`, `path`, and `queryParams`**, which describe the shape of a call without disclosing where it goes.
