# Data sanitization

This directory is where Apollo's custom redactors are specified, one file per sensitive area:

| Area | Doc |
| --- | --- |
| JWT verification and subgraph auth config | `jwt_and_auth_config.md` |
| Literal header values in `headers` config | `header_values.md` |
| GraphQL operation bodies reaching router logs | `operation_bodies.md` |
| Subgraph routing URLs | `subgraph_urls.md` |
| Redis credentials embedded in cache URLs | `redis_credentials.md` |
| TLS private keys (`tls.supergraph`, `tls.subgraph.*`, `tls.connector.*`) | `tls_private_keys.md` |
| `APOLLO_KEY` and GraphOS-key-shaped values in pod specs | `secret_shaped_env_vars.md` |
| The collecting operator's own machine environment via a host-collector's diagnostic sidecar | `host_collector_diagnostics.md` |

## The general limit: env-indirected secrets outside `router.yaml`

A secret a customer keeps out of `router.yaml` via `${env.*}` indirection, and sets as a literal pod-spec env value, is only covered on that surface if it matches a redactor specifically written for it, currently `APOLLO_KEY`/any `*_KEY`-named var (`secret_shaped_env_vars.md`), Redis URL-embedded credentials (`redis_credentials.md`), and TLS private keys (`tls_private_keys.md`). Everything else this directory protects in `router.yaml` because no recognizable value format exists to mask by and no fixed env var name exists to key on.

## Built-in redactors

troubleshoot.sh ships a default set of redactors that runs on every file regardless of spec content. This includes env-var-named secrets (`password`, `token`, `*_SECRET_ACCESS_KEY`, etc.), URL-embedded credentials, database connection strings, and a few Kubernetes-specific patterns (`last-applied-configuration` annotations, kURL bootstrap tokens). Built-ins always run before any custom redactor in this directory, on every file, whether or not a custom rule also targets that file.


## How custom redaction works

Verified by reading `github.com/replicatedhq/troubleshoot` at `v0.120.0`. **Note:** This is the version the source citations below point at, not the pinned troubleshoot.sh version — see `specs/deployment/v1/v1.md` → troubleshoot.sh support-bundle version.

Redactors are declared in a `kind: Redactor` document, delivered on the same discovered ConfigMap as the collection spec under its own `data` key. See [How the `Redactor` document is delivered](#how-the-redactor-document-is-delivered).

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

**`fileSelector` scopes a redactor to specific bundle paths.** If both `file` and `files` are omitted, the redactor runs against every file in the bundle. Every redactor we create sets one explicitly so it can't accidentally match unrelated collector output.

### Removal mechanisms

#### `removals.values`
Masks literal strings supplied in the spec. This requires knowing a customer's secrets at authoring time, and because of this, we are not currently using this mechanism.

#### Regex, single-line (no `selector`)

This matches and replaces within one line at a time. The sensitive substring must be in a capture group named `mask`, a group named `drop` is deleted, and other capture groups are reconstructed unchanged. Anything inside the match that is not in a capture group is deleted. The replacement is assembled purely from the groups ([`redact.go#L476-493`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/redact/redact.go#L476)).

**Rules to follow:**
- Capture the prefix and suffix, not just the secret.

- The `mask` group must not be able to match the empty string. Require at least one character (`+`), or anchor the group with a captured suffix. Otherwise the mask is spliced in beside the intact secret making it look lie it was redacted.

- Use exactly three capture groups — prefix, `mask`, suffix — and make every other grouping non-capturing `(?:...)`. The replacement is assembled by walking the capture groups in order and substituting the mask text for `mask`. Any group beyond those three is re-emitted into the output. A group nested inside `mask` re-emits the part of the secret it captured. Matching `password: sk-live-abc123`:

  - `(password: )(?P<mask>sk-(live|test)-\w+)(\n)` — four groups, because `(live|test)` captures. The replacement is `$1` + mask + `$3` + `$4`, and `$3` is `live` → `password: ***HIDDEN***live`
  - `(password: )(?P<mask>sk-(?:live|test)-\w+)(\n)` — three groups. The replacement is `$1` + mask + `$3` → `password: ***HIDDEN***`

  **`(?:...)` changes what is captured, not what is matched** — `sk-live-abc123` still matches in full and is still masked in full.

- Never give two groups the same name to express "either order." Go's `regexp` compiles a duplicate group name silently rather than erroring. A pattern that must handle either key order needs two separate rules, not one pattern with duplicate names.

#### Regex, two-line (`selector` set)
If `selector` matches one line, `redactor` is applied to the *next* line only. Built for pretty-printed JSON where a key and its value sit on adjacent lines (`"name": "TOKEN"` then `"value": "..."` below it). It cannot span more than two lines and does not fire if key and value are on the same line.

#### yamlPath
`yamlPath` parses the *entire target file* as YAML (JSON parses fine too), walks a dot-delimited path (`*` wildcards over map keys or array indices), and replaces the matched node wholesale with a fixed mask string, then re-serializes the whole document. If the file fails to parse, this silently no-ops. Only use `yamlPath` against collector output that is genuinely structured. Do not use `yamlPath` against a field whose value happens to be a string containing embedded YAML/JSON text.

## The `router.yaml` embedding problem

`router.yaml` is captured as a JSON-escaped string inside a JSON field — `data["configuration.yaml"]` in a ConfigMap object, within `cluster-resources/configmaps/<namespace>.json` or the `configMap` collector's output. To the file's structure it is one scalar string. Therefore, single-line `regex` with a `mask` capture group is the only way to redact a specific field inside `router.yaml`. A config schema doesn't change this: no mechanism accepts a field path for text embedded in a JSON string.

Escaping preserves the config exactly as the customer authored it. A config authored as:

```yaml
- insert:
    name: x-api-key
    value: my-secret
```

is collected as:

```json
"configuration.yaml": "- insert:\n    name: x-api-key\n    value: my-secret\n"
```

These rules follow:

- **Match YAML, not JSON.** The config was never converted — it is YAML text in a string, as above. `\"name\":\"x-api-key\"` matches nothing.
- **Assume nothing the author controls** — block vs. flow style, key order, and quoting are all the customer's choice. A field may need more than one pattern.
- **A quote is two bytes here: `\"` — never write a bare `"?`.** A bare `"?` matches the unquoted form and fails *completely* on the quoted one.

  - `\\?"?` — an optional delimiter
  - `(?:[^}\\]|\\")*?` — a class that must scan across a quoted value

  YAML requires quoting for values containing `: ` or starting with `*`, `&`, `#`, so quoted is the normal case for API keys and `Bearer ` tokens.

A failed match here is silent: the field simply stays in the bundle unredacted. A pattern that looks correct against pretty-printed YAML can still fail against its escaped form so each must be tested against a real collected bundle.

## The 10MB line-length cap

Single-line `regex` scans with a `bufio.Scanner` capped at `SCANNER_MAX_SIZE = 10MB` per line. If a line exceeds it, redaction of that file fails and the redacted copy is discarded. In this case the collector's unredacted original is what gets packaged with an error reported along with the support bundle.

The `configmaps` surfaces are bounded well under the cap by Kubernetes' ~1MiB ConfigMap limit, so this is unlikely to fire in practice — but if it ever does, read the reported error as [the bundle is not safe to share](#a-reported-error-means-the-bundle-is-not-safe-to-share)..

### A reported error means the bundle is not safe to share

This should be included in our customer facing docs.

| What the customer sees | What it means |
| --- | --- |
| A bundle, with sections missing | Expected. Absences are explained by `meta.json`. Safe to share. |
| A bundle, **and a reported error** | Redaction may not have run on some file. **Do not share until the error is understood.** |

## Knowing whether a redactor fired

Every mechanism here fails silently, so verification needs a way to tell a rule that matched nothing apart from a field that was legitimately absent.

- **For verification runs:** point the spec's `redactUri` at a throwaway endpoint. troubleshoot `PUT`s a per-redactor report there (redactor name, file, line, characters removed) — the positive control every rule in this directory needs.
- **A negative `CharactersRemoved` is a bug**, it means the mask was spliced in beside a secret it left intact.
- **`yamlPath` rows report `Line: 0`** — expected, not a defect.
- **Never set `redactUri` in the shipped spec.** - It belongs only ina verification harness. It sends the report to an external endpoint.

## Choosing a mechanism

The `helm` collector never captures the router's configuration values — only release metadata (name, chart, version, revision history), since `collectValues` is never set to `true` (see `specs/collection/base_spec.md` → `router.yaml` capture). So `helm/*.json` never carries a router secret to redact in the first place, and every `router.yaml`-scoped redactor in this directory has exactly one surface and one mechanism to reach for:

| Surface | Shape | Mechanism |
| --- | --- | --- |
| `cluster-resources/configmaps/*.json`, `configmaps/*/*.json` | `router.yaml` as a JSON-escaped string — one long line | Single-line `regex`. |
| `cluster-resources` pod-spec JSON (`pods`, `deployments`, etc.) | Genuinely structured JSON, not an embedded string | Two-line `selector`/`redactor` (env `name`/`value` on adjacent lines), or single-line `regex` for format-based rules. |

`yamlPath` isn't used by any current rule — nothing here needs its whole-document re-serialization.

## How the `Redactor` document is delivered

Collection discovers its spec by label (`troubleshoot.sh/kind: support-bundle` on a ConfigMap or Secret, per `specs/deployment/v1/v1.md`). The `Redactor` document rides along on that same object, under its own `data` key (`redactor-spec`, alongside the spec's own `support-bundle-spec`). So the chart's `base-spec-configmap.yaml` template just needs a second `data` key holding the rendered `Redactor` document.
