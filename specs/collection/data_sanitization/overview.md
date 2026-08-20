# Data sanitization

Redaction is part of the collection layer, not a separate concern from it — per `specs/architecture.md`, redactors live in the same spec YAML as the collectors and version with it. This directory is where Apollo's custom redactors are specified, one file per sensitive area:

| Area | Doc |
| --- | --- |
| JWT verification and subgraph auth config | `jwt_and_auth_config.md` |
| Literal header values in `headers` config | `header_values.md` |
| GraphQL operation bodies reaching router logs | `operation_bodies.md` |
| Subgraph routing URLs | `subgraph_urls.md` |
| Graph schema/SDL | `schema_sdl.md` |

Every file here is scoped to the router's own `router.yaml` (captured per `specs/collection/base_spec.md` → `router.yaml` capture) and adjacent collected surfaces (logs, the schema ConfigMap). Generic secrets — cloud credentials, standard connection strings, tokens with recognizable env-var names — are already covered by troubleshoot.sh's built-in redactors, which run unconditionally on every collected file with no spec authoring required (see below). These docs exist because the router's own config shape has fields no generic pattern knows about.

## How custom redaction actually works, mechanically

Verified against `github.com/replicatedhq/troubleshoot` at the pinned engine floor, `v0.120.0`.

**A redactor is a separate document, not a field on the collection spec.** `SupportBundleSpec` has no `redactors` field at all — redaction is declared as its own `kind: Redactor` document, shipped as an additional `---`-separated YAML document inside the same rendered spec file (this is what "lives in the same spec YAML" means in practice: one file, multiple documents):

```yaml
apiVersion: troubleshoot.sh/v1beta2
kind: Redactor
metadata:
  name: router-diagnostics-redactors
spec:
  redactors:
    - name: string                # optional, appears in the redaction report
      fileSelector:
        file: string               # single glob, OR:
        files: [string, ...]       # a list of globs, OR'd together
      removals:
        values: [string, ...]      # literal strings, masked wherever found
        regex:
          - selector: string       # optional: a context-line pattern
            redactor: string       # the pattern actually replaced
        yamlPath: [string, ...]    # dot-delimited path into a parsed YAML/JSON document
```

**`fileSelector` scopes a redactor to specific bundle paths.** If both `file` and `files` are omitted, the redactor runs against every file in the bundle — every redactor in the docs below sets one explicitly, so it can't accidentally match unrelated collector output.

**Three distinct removal mechanisms, each with a different reach:**

- **`regex`, single-line** (no `selector`) — matches and replaces within one line at a time. The sensitive substring must be in a capture group named `mask`; a group named `drop` is deleted; anything else captured is reconstructed into the output unchanged. This means the redactor pattern has to name the secret itself as `mask`, not rely on masking the whole match.
- **`regex`, two-line** (`selector` set) — if `selector` matches one line, `redactor` is applied to the *next* line only. Built for pretty-printed JSON where a key and its value sit on adjacent lines (`"name": "TOKEN"` then `"value": "..."` below it). It cannot span more than two lines and does not fire if key and value are on the same line.
- **`yamlPath`** — parses the *entire target file* as YAML (JSON parses fine too, since JSON is a YAML subset), walks a dot-delimited path (`*` wildcards over map keys or array indices), and replaces the matched node wholesale with a fixed mask string, then re-serializes the whole document. If the file fails to parse, this silently no-ops — no error, nothing masked, no indication anything was skipped. Only use `yamlPath` against collector output that is genuinely structured (a JSON object graph, like `clusterResources`'s raw Kubernetes API dumps) — not against a field whose *value* happens to be a string containing embedded YAML/JSON text.

**The gotcha that matters most for `router.yaml`.** The router's config is captured as a multi-line YAML string sitting inside a JSON field — `data["configuration.yaml"]` inside a ConfigMap object, itself inside `cluster-resources/configmaps/<namespace>.json` or the `configMap` collector's own output. To the file's own top-level JSON structure, that config text is just one scalar string value. Two consequences:
  - `yamlPath` can mask that string's contents **as a whole** (useful for the schema/SDL case — see `schema_sdl.md`) but cannot reach a single field *inside* it. It has no way to descend into embedded text and redact one YAML key without removing the entire block.
  - The embedded YAML's internal newlines are the two-character escape `\n`, not real line breaks, so from a line-scanning redactor's point of view the entire config is one very long line. The two-line `selector`/`redactor` mechanism (built for adjacent-line JSON) cannot be used here — there is no second line. **Single-line `regex` with a `mask` capture group, written against the JSON-escaped text, is the only mechanism that can redact a specific field inside the embedded `router.yaml`.** Every redactor in `jwt_and_auth_config.md` and `header_values.md` is written this way, and every one needs to be tested against an actual collected bundle before being trusted — a pattern that looks right against pretty-printed YAML can still fail against its JSON-escaped form, and a failed match here fails silently (the field just stays in the bundle unredacted, with no error).
  - **The escaped text is the router.yaml exactly as authored, not re-serialized into a different shape.** JSON-escaping only turns a real newline into the literal two characters `\n` and a real quote into `\"` — it does not flatten block-style YAML into a single-line JSON object or a flow-style map. A pattern written against `\"name\":\"...\",\"value\":\"...\"` or `insert:{name:...,value:...}` is assuming a shape this pipeline never produces. Every redactor targeting a field inside `router.yaml` should be written against `key:` / `value:` as separate, `\n`-separated, indented lines — the actual block-style shape — and even then, key ordering and quoting of the value are things the customer's own authoring controls, not something this project can assume from the config schema alone.

**Built-in redactors, for context.** troubleshoot.sh ships a default set that runs on every file regardless of spec content — env-var-named secrets (`password`, `token`, `*_SECRET_ACCESS_KEY`, etc.), URL-embedded credentials, database connection strings, and a few Kubernetes-specific patterns (`last-applied-configuration` annotations, kURL bootstrap tokens). troubleshoot.sh's own docs state these "cover common patterns but are not exhaustive" — which is exactly why the router's own config surface needs the redactors specified in this directory; nothing generic knows the shape of `authentication.subgraph.all.aws_sig_v4.hardcoded`.

## Open implementation question: how the `Redactor` document is delivered

Discovery for collection is by label (`troubleshoot.sh/kind: support-bundle` on a ConfigMap or Secret, per `specs/deployment/v1/v1.md` → Verified against the troubleshoot.sh docs). Whether `--load-cluster-specs` discovers a `Redactor` document the same way — a second YAML document inside the same ConfigMap's `spec.yaml` key, or a separate object with its own kind label — was not resolved by the research behind this directory and needs to be verified before `specs/deployment/v1/v1.md`'s chart templates are finalized. This affects chart wiring, not what gets redacted, so it doesn't block writing the redactors themselves, but it's a real gap, not a formality.

## What these redactors do not solve

Every redactor here is regex- or path-based text matching, not schema-aware parsing of the router's config. A future router release can rename or restructure any of the fields cited in these docs, silently breaking a redactor with no error — the same silent-failure risk `yamlPath` has when a file doesn't parse. **Re-verify every citation in this directory whenever the router version these specs are pinned to changes**, the same discipline `specs/collection/base_spec.md` applies to its own chart-version citations.
