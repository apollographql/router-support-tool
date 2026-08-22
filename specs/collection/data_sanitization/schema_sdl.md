# Schema/SDL

## The Problem

This is the outlier in this directory: it is not a redactor that masks one sensitive field inside a larger document, because there's no smaller sensitive substring to extract — the graph schema is, in its entirety, the thing a customer might not want to share. So the mechanism is presence control, not masking, and most of what governs it is already specified elsewhere. This doc exists to describe the redaction mechanism specifically: the render-time toggle and where the schema actually lands are owned by other files and not restated here.

- **What triggers inclusion, and where the schema ConfigMap actually lands:** `specs/collection/base_spec.md` → Where graph schema/SDL actually lands.
- **The customer-facing toggle (`redaction.includeSchema`) and its render-time semantics:** `specs/collection/meta_json.md` → Render-time facts, and `specs/deployment/v1/v1.md` → Chart values.

This document describes **how `redaction.includeSchema: false` is actually implemented as a redactor**, given that `clusterResources` sweeps every ConfigMap in the namespace unconditionally — including the `<release>-supergraph` ConfigMap — with no per-ConfigMap opt-out available at the collector level (per `specs/collection/base_spec.md`, there is no dedicated schema collector to simply omit).

### Why it reaches the bundle

`redaction.includeSchema: false` is a chart-level decision, but it has nothing to say to `clusterResources` — that collector sweeps every ConfigMap in the namespace regardless of any chart value, and the supergraph ConfigMap carries no marker distinguishing it from any other. So the opt-out can't work by *not collecting* the schema, it has to work by collecting it and then removing it, which is exactly what a redactor is for.

## Redactor: schema opt-out

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

Rendered into the spec only when `redaction.includeSchema: false` — i.e., this whole redactor block is conditional on the chart value, not always present.

**Notes:**

- **No third rule is proposed for the `helm` collector's output**, deliberately. `.Values.supergraphFile` is itself a Helm value, so `collectValues: true` may capture the raw schema text a second (or third) time in the Helm values layer — see `jwt_and_auth_config.md` for the same gap affecting the other four redactors. But unlike the two rules above, nobody has verified whether the schema actually appears there at all, or whether `helm`'s output format even permits a `yamlPath`-style removal against it. Writing a placeholder redactor for an unconfirmed leak, with no removal that actually does anything, would be worse than no rule — it would look handled and not be.

- **Required before this is considered done:** collect with `redaction.includeSchema: false` against a router with `.Values.supergraphFile` set, then confirm:
    - The schema is actually absent from **every** file in the resulting bundle — not just `cluster-resources/configmaps/*.json`, and not just that the redactor spec parses.
    - `cluster-resources/configmaps/*.json`'s actual shape (bare array, `{"items": [...]}` wrapper, or something else) — the `items.*` wildcard above assumes a Kubernetes List-response shape by analogy, not by verification.
    - Whether the schema also lands at `configmaps/<namespace>/<release>-supergraph.json`, via the standalone `configMap` collector — the supergraph ConfigMap shares the `app.kubernetes.io/name=router` label that collector matches on for the main config ConfigMap (`specs/collection/base_spec.md` → Where graph schema/SDL actually lands), and nothing in `base_spec.md` rules this out; it only documents the `clusterResources` path. The second redactor rule above targets this path defensively (a single-object `yamlPath`, not an array, matching that collector's per-file output).
    - Whether `yamlPath`'s silent-no-op-on-parse-failure behavior (per `overview.md`) applies per-file or per-document — a per-file quirk that trips a parse failure would let the schema ship despite the opt-out with no indication anything went wrong.

## What's deliberately left visible

When `redaction.includeSchema` is `true` (the default), the schema is included in full — no field-level or directive-level filtering is proposed here. Even with presence resolved, schema content itself is not risk-free: type names, field names, descriptions, and directive arguments (`@tag`, custom directives) can incidentally reveal internal system names or business logic a customer didn't intend to expose. That's a content-sensitivity question about the schema itself, distinct from the "should this be in the bundle at all" question `redaction.includeSchema` answers, and currently we do not propose field-level schema redaction (masking one type or directive within an otherwise-included schema) — `redaction.includeSchema` is all-or-nothing by design, per `specs/deployment/v1/v1.md`. Anything more granular would be a new, separate design proposal, not an extension of what's specified here.
