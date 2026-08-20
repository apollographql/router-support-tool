# Schema/SDL

This is the outlier in this directory: it is not a redactor that masks one sensitive field inside a larger document, because there's no smaller sensitive substring to extract — the graph schema is, in its entirety, the thing a customer might not want to share. So the mechanism is presence control, not masking, and most of what governs it is already specified elsewhere. This doc exists to describe the redaction mechanism specifically; the render-time toggle and where the schema actually lands are owned by other files and not restated here.

- **What triggers inclusion, and where the schema ConfigMap actually lands:** `specs/collection/base_spec.md` → Where graph schema/SDL actually lands.
- **The customer-facing toggle (`redaction.includeSchema`) and its render-time semantics:** `specs/collection/meta_json.md` → Render-time facts, and `specs/deployment/v1/v1.md` → Chart values.

What belongs here is the one thing those files don't cover: **how `redaction.includeSchema: false` is actually implemented as a redactor**, given that `clusterResources` sweeps every ConfigMap in the namespace unconditionally — including the `<release>-supergraph` ConfigMap — with no per-ConfigMap opt-out available at the collector level (per `specs/collection/base_spec.md`, there is no dedicated schema collector to simply omit).

## Why content redaction, not just customer opt-in, matters at all

Even setting the presence-vs-absence question aside, schema content itself is not risk-free. Type names, field names, descriptions, and directive arguments (`@tag`, custom directives) can incidentally reveal internal system names or business logic a customer didn't intend to expose — this is a content-sensitivity question about the schema itself, distinct from the "should this be in the bundle at all" question `redaction.includeSchema` answers. This directory does not propose field-level schema redaction (masking one type or directive within an otherwise-included schema) — `redaction.includeSchema` is all-or-nothing by design, per `specs/deployment/v1/v1.md`. Anything more granular would be a new, separate design proposal, not an extension of what's specified here.

## Implementation candidate, not yet verified against a real bundle

Unlike `router.yaml`'s config fields (`jwt_and_auth_config.md`, `header_values.md`), the schema text does **not** need a single-line `regex` with a `mask` group. The reason is the same distinction `overview.md` draws between `yamlPath`'s two very different use cases: `clusterResources`'s ConfigMap sweep (`cluster-resources/configmaps/<namespace>.json`) is genuine structured JSON — an array of ConfigMap objects, each with a `data` map — not a string field with embedded YAML/JSON text. `yamlPath` can walk into that structure and mask an entire matched value, which is exactly what "strip the schema field entirely" needs:

```yaml
- name: router-schema-sdl-opt-out-cluster-resources
  fileSelector:
    files:
      - "cluster-resources/configmaps/*.json"
  removals:
    yamlPath:
      - "items.*.data.supergraph-schema\\.graphql"
- name: router-schema-sdl-opt-out-configmap-collector
  fileSelector:
    files:
      - "configmaps/*/*.json"
  removals:
    yamlPath:
      - "data.supergraph-schema\\.graphql"
```

**No third rule is proposed yet for the `helm` collector's output**, deliberately — unlike the two rules above, nobody has verified whether the schema actually appears there at all, or whether `helm`'s output format even permits a `yamlPath`-style removal against it. Writing a placeholder redactor for an unconfirmed leak, with no removal that actually does anything, would be worse than no rule — it would look handled and not be. This gap is tracked below, not papered over with empty YAML.

Rendered into the spec only when `redaction.includeSchema: false` — i.e., this whole redactor block is conditional on the chart value, not always present.

**This is a proposal, not a confirmed mechanism, and every path in it needs verification before being trusted — more so than any other redactor in this directory, because a miss here is a full leak of the exact thing the customer opted out of, not a partial one.**

- **`cluster-resources/configmaps/*.json`'s actual shape** — bare array, `{"items": [...]}` wrapper, or something else — was not confirmed against the collector's actual output during the research behind this directory. The `items.*` wildcard above assumes a Kubernetes List-response shape by analogy, not by verification.
- **A second sweep path this directory missed initially:** the supergraph ConfigMap carries the same `app.kubernetes.io/name=router` label as the main config ConfigMap (per `specs/collection/base_spec.md` → Where graph schema/SDL actually lands), and the standalone `configMap` collector matches on exactly that label for the main ConfigMap. Whether it *also* matches the supergraph ConfigMap — landing a second, unredacted copy at `configmaps/<namespace>/<release>-supergraph.json` — is not ruled out by anything currently written in `base_spec.md`, which only states where the schema lands via `clusterResources`. The second redactor rule above targets that path defensively, with a `yamlPath` expression for a single-object file rather than an array (since that collector's output is one ConfigMap per file, not a sweep) — but whether the schema actually lands there at all needs confirming before this rule can be trusted either way.
- **A third possible copy, via the `helm` collector:** `.Values.supergraphFile` is itself a Helm value, so `collectValues: true` may capture the raw schema text a second (or third) time in the Helm values layer — see `jwt_and_auth_config.md` for the same gap affecting the other four redactors. The third rule above is a placeholder, not a real redactor — nobody has verified whether `helm`'s output format even permits a `yamlPath`-style structural removal, and writing a fake `values: []` removal is a marker for "this needs its own investigation," not a fix.
- **Whether `yamlPath`'s silent-no-op-on-parse-failure behavior (per `overview.md`) applies per-file or per-document** — if any of these three targeted files has a per-file quirk that trips a parse failure, that rule fails with no indication, and the schema ships despite the opt-out.

**Required before this is considered done:** collect with `redaction.includeSchema: false` against a router with `.Values.supergraphFile` set, and confirm the schema is actually absent from **every** file in the resulting bundle — not just `cluster-resources/configmaps/*.json`, and not just that the redactor spec parses. Given the severity of a miss here, this is the single highest-priority item in this directory's verification backlog.
