# Verification plan

This spec lays out how we validate the support tool's behavior. We do not restate what is collected or how sanitization works here (see`specs/collection/base_spec.md` and `specs/collection/data_sanitization/`). This document is about how we prove those specs behave as intended, against real clusters.

## What we're testing

### Deployment tiers

Two of the deployment tiers in `specs/deployment/v1/v1.md` are in scope for this plan: the official Apollo Helm chart and raw manifest/custom deployment.

### Collection modes

Both `mode: local` and `mode: job` (`specs/deployment/v1/v1.md`) need coverage, but not symmetrically:

- `mode: job` pins the troubleshoot.sh support-bundle version via the image tag, which makes it the reproducible path — prefer it as the default.

- `mode: local` needs its own dedicated pass, but not full re-coverage of everything in this plan. What's actually different in that mode is the customer's own `kubectl`-based invocation path and permissions.

### Router condition matrix
Each of these scenarios will be tested per deployment tier: the official Apollo Helm chart and raw manifest/custom deployment. See [Applying the router condition matrix to RTF](#applying-the-router-condition-matrix-to-rtf) for how we will test this.

|  | Scenario | What it validates |
| --- | --- | --- |
| 1 | **All routers healthy** | Bundle collects everything expected, redaction runs, `meta.json` is accurate. |
| 2 | **Some routers degraded** [1] | The tool identifies and collects from the affected pods. Healthy neighbors show no behavioral impact from collection running against degraded pods. |
| 3 | **All routers degraded** [1] | The "safe to run at any time" claim holds under genuine degradation. A bundle is still produced. |
| 4 | **Routers under-resourced** | The negligible-resource-consumption claim holds when collection runs against a container already near its cgroup limit. This is also where an in-container collector would do the most damage if one is ever proposed — this scenario is the standing regression check against that. |
| 5 | **Router recently restarted** | `logs` collector's previous-container request produces `<name>-previous.log` and startup-time errors are present in the bundle. |
| 6 | **OOM in progress**: the router container's memory usage is actively climbing toward its cgroup limit (not yet kernel-OOM-killed). | Validates that running collection **while** this is happening doesn't push it over the edge. |

**[1]** We will test two degradation scenarios:
1. The router's `/metrics` endpoint is unresponsive or returns errors while the router's main traffic port and k8s health checks are fine.
2. The router returns errors on all client traffic.

### Collector attribution scenarios

These tests validate that an empty section is always attributable to a specific, named cause. Each of these scenarios will be tested per deployment tier: the official Apollo Helm chart and raw manifest/custom deployment. See [Applying the collector attribution scenarios to RTF](#applying-the-collector-attribution-scenarios-to-rtf) for how we test these.

|  | Scenario | What it validates |
| --- | --- | --- |
| 1 | **Metrics/observability not configured** | Router deployed with Prometheus scraping disabled. Confirms the bundle still collects and the metrics section is empty. |
| 2 | **RBAC permission declined for a collector** | Environment's ServiceAccount/Role deliberately omits a permission a collector needs (e.g. `nodes/proxy` for `nodeMetrics`, or read access to the router's ConfigMap). The affected collector degrades to empty/an attributable error rather than crashing the whole bundle.

### Redaction Verification

Redaction fails silently so every test run has to confirm the specific secret value is actually gone not just that a rule reported firing:

1. Prove each redactor fired and that the secret is gone from the artifact a customer would receive.

2. **Per-redactor verification:** see the table below and `specs/collection/data_sanitization/` for details. 

3. **`helm/*.json` order independence, regardless of redactor:** a `yamlPath` rule rewrites that file from JSON to YAML in place (see `specs/collection/data_sanitization/overview.md` → Order independence on `helm/*.json`) so at least one run must apply redactors in both possible orders to confirm the format-agnostic regex requirement holds.

| Redactor | Required scenario (condensed from the redactor's own spec) |
| --- | --- |
| `jwt_and_auth_config.md` | Two non-`Authorization` JWKS fetch headers (block-style, single-entry flow, quoted), a hardcoded `aws_sig_v4` key pair, a `default_chain` block. Confirm all masked, while header names/JWKS URL/issuer/algorithms/`default_chain` profile survive. Also confirm the known gap: in a two-entry flow list, only the first value is masked. |
| `header_values.md` | All three of `insert.value`, `insert.default` (JSONPath deliberately unresolvable), and `propagate.default` (source header absent) set to distinct values. Confirm masking on both the `configMap`/`clusterResources` surface and the `helm` collector's output. |
| `operation_bodies.md` | Supergraph request/response logging enabled; run an operation with a sentinel value in variables and an escaped quote in the query string. Confirm the sentinel is absent, surrounding log fields (`level`, `target`, trace IDs) survive, and every line is still valid JSON. Repeat with `format: text` to observe the documented gap there. |
| `redis_credentials.md` | A URL-embedded credential in both `user:pass@` and pathless `:pass@` forms, `username`/`password` as separate fields (quoted in one cache block, unquoted in another), and at least one Redis-backed cache left unconfigured. Confirm masking on both surfaces and that the unconfigured cache's absence is attributable. |
| `subgraph_urls.md` | `override_subgraph_url` set for two subgraphs (one quoted, one not) followed by a top-level key; a `supergraphFile` schema with `@join__graph` URLs and a connector `baseURL`; a `@link` directive. Confirm masking everywhere, the key after the block survives, subgraph names/`@link` URL survive, and schema patterns still fire on `helm/*.json` after a `yamlPath` rule re-serializes it as YAML. |

### Chart rendering across tiers and modes

The `router-diagnostics` chart must render correctly (`helm template` succeeds, output is valid) for every deployment tier × collection mode combination in scope.

## How this gets tested

### RTF Orchestrator

Used for everything behavioral: the router condition matrix, redaction, and troubleshoot.sh version coverage above.

#### What "environment" means for us

Each scenario is a `K8sEnvironment` that RTF deploys. We start with all routers healthy, a router Deployment and its ConfigMap, matching the official Apollo Helm chart or raw-manifest tier (see [Deployment tiers](#deployment-tiers)). An environment for this tool needs:

- The healthy router Deployment and ConfigMap above.

- **The router's own container logs labeled `rtf.io/log-collection: "true"`.** This gets RTF to pull the *raw*, pre-redaction container logs into its own `output/logs/` alongside our tool's collected (redacted) bundle in the same run — see [Redaction verification technique](#redaction-verification-technique) below for why that matters.

- A router config (`router.yaml`) that exercises every custom redactor's trigger conditions. See [Redaction](#redaction) above.

Everything that makes a test case *not* healthy happens after that, from the Scenario (see below).

#### Applying the router condition matrix to RTF

The environment itself is the same across every test case, and so is the Scenario's `command`. What varies is the matrix's scenario value, passed into that same script via `env_vars` (e.g. `SCENARIO: "{{ scenario }}"`). The script branches internally on that value to put the environment into whatever shape the test case needs, then runs the actual collection/verification commands. "All routers healthy" is simply the no-op branch.

- **Some vs. all degraded:** `kubectl get pods -l app=router` lists the replicas directly, and the script `patch`es a subset of them (or all, for "all degraded") into whichever of the two degradation cases that test case needs — see the router condition matrix footnote above.

- **Recently restarted:** the script triggers a restart directly (e.g. `kubectl rollout restart`), timed however precisely the test needs relative to when collection runs.

The environment does differ for the Routers under-resourced test case, where `resources.limits` will be set tight from the start. We can verify this by reading `node-metrics/*.json` and `router-metrics/result.json` against `resources.limits`. Note: `router-metrics/result.json` only populates if the router's Prometheus exporter is enabled in this scenario's config and its worth checking whether the router can prioritize serving `/metrics` even under memory pressure, so this signal doesn't just go dark exactly when it matters most.

#### Applying the collector attribution scenarios to RTF

Both are also just matrix dimension values on the same templated manifests, not separate environments:

- **Metrics/observability not configured** — the router manifest omits the Prometheus scrape annotations/exporter config for this dimension value.

- **RBAC permission declined** — the environment's Role manifest omits a specific permission (e.g. `nodes/proxy`) for this dimension value, rather than granting the full set every other test case uses.

#### Redaction verification technique

- Point the spec's `redactUri` at a throwaway endpoint to get troubleshoot.sh's per-redactor report. Only set this for verification runs, never in the shipped spec. Reuse the same endpoint built for [bundle retrieval](#bundle-retrieval-in-rtf) rather than standing up a second one.

- Label the router service `rtf.io/log-collection: "true"` so RTF pulls its raw, pre-redaction logs alongside the redacted bundle in the same run, allowing us to search for a known secret in both the pre-redacted and redaction versions of the bundle.

#### Collection mode and troubleshoot.sh version coverage in RTF

The floor and current-release versions are two separate environment variants, differing only in which `support-bundle` binary/image the environment stages.

#### Bundle retrieval in RTF

Use the `job.storage.provider: url` option (see `specs/storage/object_storage.md`). We will drop a plain `http.server` script into the environment via a file provider, run it reachably from the Job, and point `job.storage.url.endpoint` at it. The Job pushes the bundle there directly once collection finishes (via PUT request). This also answers how the Scenario knows the Job is done, the request arriving is the signal.

### Other CI checks

Used for structural checks that don't need a real cluster.

#### Chart rendering across tiers and modes

Running `helm template` with each tier's (official chart, raw-manifest) and mode's (`local`, `job`) actual values, and validating the output.

#### Spec linting across troubleshoot.sh versions

Run `support-bundle lint` against the rendered spec once per troubleshoot.sh version in scope — a matrix of pinned `support-bundle` binaries (the declared floor, a current release), each linting the same rendered spec.
