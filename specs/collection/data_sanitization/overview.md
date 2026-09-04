# Data sanitization

This directory is where Apollo's custom redactors are specified, one file per sensitive area:

| Area | Doc |
| --- | --- |
| JWT verification and subgraph auth config | `jwt_and_auth_config.md` |
| Literal header values in `headers` config | `header_values.md` |
| GraphQL operation bodies reaching router logs | `operation_bodies.md` |
| Subgraph routing URLs | `subgraph_urls.md` |
| Redis credentials embedded in cache URLs | `redis_credentials.md` |

Every file here is scoped to the router's own `router.yaml` (captured per `specs/collection/base_spec.md` → `router.yaml` capture) and adjacent collected surfaces (logs, the schema ConfigMap). Generic secrets such as tokens with recognizable env-var names are already covered by troubleshoot's built-in redactors, which run unconditionally on every collected file. These docs exist because the router's own config shape has fields no generic pattern knows about.

## Built-in redactors

troubleshoot.sh ships a default set of redactors that runs on every file regardless of spec content. This includes env-var-named secrets (`password`, `token`, `*_SECRET_ACCESS_KEY`, etc.), URL-embedded credentials, database connection strings, and a few Kubernetes-specific patterns (`last-applied-configuration` annotations, kURL bootstrap tokens).

## How custom redaction works

Verified by reading `github.com/replicatedhq/troubleshoot` at `v0.120.0`. **Note:** This is the version the source citations below point at, not a minimum supported version, see `specs/deployment/v1.md` → Collection engine version.

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

## The `helm` collector's output

The `helm` collector captures a second copy of the same config values from the Helm values layer (see `specs/collection/base_spec.md` → `router.yaml` capture), so every secret targeted above appears here too, but in a different shape. Because the structure is real, `yamlPath` works here and is the mechanism to reach for. A hardcoded header value, for example, is reachable at:

```
*.releaseHistory.*.values.router.configuration.headers.all.request.*.insert.value
```

Two things to get right when writing a path:

- **It must begin with `*`** — the file's root is a JSON array (`[]ReleaseInfo`), so the document opens `[ { "releaseName": ..., "releaseHistory": [...] } ]` ([`yaml.go#L88-135`](https://github.com/replicatedhq/troubleshoot/blob/v0.120.0/pkg/redact/yaml.go#L88)).
- **Check the root shape per collector — it isn't always an array.** `cluster-resources/configmaps/*.json`, for instance, is a single object, so a path there would omit the leading `*`. A path that doesn't match the root shape masks nothing, silently.

**Single-line `regex` is still right in two cases**, subject to the format-agnostic requirement in [Order independence on `helm/*.json`](#order-independence-on-helmjson):

- **The secret is a substring, not a field** — a credential inside a URL can't be addressed by a path.
- **As a safety net for a distinctive key** — matching `secret_access_key` anywhere also catches a copy outside the documented path, which a path-bound rule would miss.

## The 10MB line-length cap

Single-line `regex` scans with a `bufio.Scanner` capped at `SCANNER_MAX_SIZE = 10MB` per line. If a line exceeds it, redaction of that file fails and the redacted copy is discarded. In this case the collector's unredacted original is what gets packaged with an error reported along with the support bundle. 

Only `helm/*.json` is plausibly at risk — the `configmaps` surfaces are bounded well under the cap by Kubernetes' ~1MiB ConfigMap limit, but Helm's gzipped storage means a release's decompressed values aren't bounded the same way.

**Remedy:** measure `helm/*.json`'s longest line against the largest realistic supergraph before treating these rules as verified, and read any reported collection error as [the bundle is not safe to share](#a-reported-error-means-the-bundle-is-not-safe-to-share).

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

## Order independence on `helm/*.json`

Because `helm/*.json` is the one surface where `yamlPath` and `regex` rules both apply, the order they run in has to not matter. This is because  A `yamlPath` redactor rewrites the file it changes as YAML. The `.json` extension is unchanged, so the file keeps its name and changes its syntax:

```
"secret_access_key": "AKIAIOSFODNN7EXAMPLE"   ->   secret_access_key: '***HIDDEN***'
```

**The requirement that follows: every regex targeting `helm/*.json` must match both forms.** Make the quoting optional rather than assuming it — `("?secret_access_key"?:\s*"?)` matches the JSON and YAML spellings alike, where `("secret_access_key": ")` matches only the pre-`yamlPath` one. A pattern that assumes JSON will fire or not fire depending on rule order.

Two consequences worth carrying into testing:

1. **A bundle may contain YAML in a `.json` file**, so tooling that assumes `helm/*.json` parses as JSON can break. Worth confirming against a real bundle rather than assuming.

2. **This is why `subgraph_urls.md`'s schema patterns need checking on this surface specifically.** They target long single-line strings, a YAML re-marshal can re-emit a long scalar as a block scalar with real newlines, and a single-line regex cannot match across those.

## Choosing a mechanism

The two surfaces are not equivalent, and the choice is forced by file shape, not preference:

| Surface | Shape | Mechanism |
| --- | --- | --- |
| `cluster-resources/configmaps/*.json`, `configmaps/*/*.json` | `router.yaml` as a JSON-escaped string — one long line | Single-line `regex`. |
| `helm/*.json` | Genuine structured JSON, **array at the root** | **`yamlPath` where the field's path is known** (paths start with `*`). Single-line `regex` for value-substrings or as a safety net — must be format-agnostic. No two-line `regex`. |

**Where the same secret appears on both surfaces, it needs two rules, one per shape.** The exception is a pattern that never depends on escaping or structure, such as `://user:pass@` inside a URL, which matches identically in both (see `subgraph_urls.md`).

## How the `Redactor` document is delivered

Collection discovers its spec by label (`troubleshoot.sh/kind: support-bundle` on a ConfigMap or Secret, per `specs/deployment/v1/v1.md`). The `Redactor` document rides along on that same object, under its own `data` key (`redactor-spec`, alongside the spec's own `support-bundle-spec`). So the chart's `spec-configmap.yaml` template just needs a second `data` key holding the rendered `Redactor` document.
