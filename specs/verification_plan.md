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
| 2 | **Some routers misbehaving** | The tool identifies and collects from the affected pods. Healthy neighbors show no behavioral impact from collection running against degraded pods. |
| 3 | **All routers misbehaving** | The "safe to run at any time" claim holds under genuine degradation. A bundle is still produced. |
| 4 | **Routers under-resourced** | The negligible-resource-consumption claim holds when collection runs against a container already near its cgroup limit. This is also where an in-container collector would do the most damage if one is ever proposed — this scenario is the standing regression check against that. |
| 5 | **Router recently restarted** | `logs` collector's previous-container request produces `<name>-previous.log` and startup-time errors are present in the bundle. |
| 6 | **OOM in progress**: the router container's memory usage is actively climbing toward its cgroup limit (not yet kernel-OOM-killed). |  Validates that running collection **while** this is happening doesn't push it over the edge. |

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


### troubleshoot.sh version coverage

Test against various troubleshoot.sh versions for drift.

- **Test the declared floor and a current release**
- **The declared minimum version is set from a verified test run.** If this plan hasn't run the floor version yet, treat the minimum as unknown in `specs/deployment/v1/v1.md`.
- **Whenever a spec change adds a field, verify what the floor version does with a field it doesn't recognize** — hard error or silent ignore.
- Every run should read the produced bundle's `version.yaml` and compare it against the intended version.
- This will get tested two ways: a static, offline lint per version and real execution per version (RTF). See [How this gets tested](#how-this-gets-tested).

### Chart rendering across tiers and modes

The `router-diagnostics` chart must render correctly (`helm template` succeeds, output is valid) for every deployment tier × collection mode combination in scope.

## How this gets tested

### RTF Orchestrator

Used for everything behavioral: the router condition matrix, redaction, and troubleshoot.sh version coverage above.

#### What "environment" means for us

Each scenario is a `K8sEnvironment` that RTF deploys. An environment for this tool needs:

- A router Deployment and its ConfigMap, matching the official Apollo Helm chart or raw-manifest tier (see [Deployment tiers](#deployment-tiers)).
- The `router-diagnostics` chart's *rendered output* included as one of the environment's manifests, for both `mode: local` and `mode: job`.
- A control process, present unmodified in every environment, what it does depends on the test case. See [Applying the router condition matrix to RTF](#applying-the-router-condition-matrix-to-rtf).
- **The router's own container logs labeled `rtf.io/log-collection: "true"`.** This gets RTF to pull the *raw*, pre-redaction container logs into its own `output/logs/` alongside our tool's collected (redacted) bundle in the same run — see [Redaction verification technique](#redaction-verification-technique) below for why that matters.
- A router config (`router.yaml`) that exercises every custom redactor's trigger conditions. See [Redaction](#redaction) above.

#### Applying the router condition matrix to RTF

The manifest itself is the same across all but one of the test cases. What varies is the Scenario's own behavior. We will use one router image/Deployment shape for every scenario and run a second control process on its own port. Once the environment is healthy and the Scenario has started, it hits that port to make the router misbehave.

- **Some vs. all misbehaving:** A headless Service (`clusterIP: None`) gives the Scenario DNS-addressable access to each individual pod, so it can independently target each router instances own control process, sending the trigger to just one (or a few) for "some," and to every replica's for "all."

- **Recently restarted:** use the control process to trigger an exit, triggering a normal k8s-managed restart.

- **OOM in progress:** use the control process to ramp memory in the same container. For a router-internal trigger, we can craft an operation that makes the query planner allocate a `usize::MAX`-length `Vec`, for example.
    - **Note:** if the control process does the memory-ramping rather than the router process itself, container/pod-level kubelet metrics (`nodeMetrics`) still show the pressure (same cgroup), but the router's own process-specific metric (`process_resident_memory_bytes`) may not.

The manifest does differ for the Routers under-resourced test case, where `resources.limits` will be set tight from the start. Verify by reading `node-metrics/*.json` and `router-metrics/result.json` against `resources.limits`. Note: `router-metrics/result.json` only populates if the router's Prometheus exporter is enabled in this scenario's config.

#### Applying the collector attribution scenarios to RTF

Both are also just matrix dimension values on the same templated manifests, not separate environments:

- **Metrics/observability not configured** — the router manifest omits the Prometheus scrape annotations/exporter config for this dimension value.

- **RBAC permission declined** — the environment's Role manifest omits a specific permission (e.g. `nodes/proxy`) for this dimension value, rather than granting the full set every other test case uses.

#### Redaction verification technique

- Point the spec's `redactUri` at a throwaway endpoint to get troubleshoot.sh's per-redactor report. This will only set this for verification runs. We can use the endpoint one built for [bundle retrieval](#bundle-retrieval-in-rtf) for this use case as well.

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
