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
| 6 | **OOM in progress** | This scenario currently validates that an on-demand collection **during** an OOM does not itself worsen the situation. |

### Collector attribution scenarios

These tests validate that an empty section is always attributable to a specific, named cause. Each of these scenarios will be tested per deployment tier: the official Apollo Helm chart and raw manifest/custom deployment. See [Applying the collector attribution scenarios to RTF](#applying-the-collector-attribution-scenarios-to-rtf) for how we test these.

|  | Scenario | What it validates |
| --- | --- | --- |
| 1 | **Metrics/observability not configured** | Router deployed with Prometheus scraping disabled. Confirms the bundle still collects and the metrics section is empty. |
| 2 | **RBAC permission declined for a collector** | Environment's ServiceAccount/Role deliberately omits a permission a collector needs (e.g. `nodes/proxy` for `nodeMetrics`, or read access to the router's ConfigMap). The affected collector degrades to empty/an attributable error rather than crashing the whole bundle.

### Redaction Verification

Redaction fails silently so every test run has to confirm the specific secret value is actually gone not just that a rule reported firing:

1. Prove each redactor fired and that the secret is gone from the artifact a customer would receive.

2. **Per-redactor verification:** the specific cases each redactor's spec calls out. See the table below and `specs/collection/data_sanitization/` for details. 

3. **`helm/*.json` order independence, regardless of redactor:** a `yamlPath` rule rewrites that file from JSON to YAML in place (see `overview.md` → Order independence on `helm/*.json`) so at least one run must apply redactors in both possible orders to confirm the format-agnostic regex requirement actually holds there.

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
- This gets tested two ways: a static, offline lint per version and real execution per version (RTF). See [How this gets tested](#how-this-gets-tested).

### Chart rendering across tiers and modes

The `router-diagnostics` chart must render correctly (`helm template` succeeds, output is valid) for every deployment tier × collection mode combination in scope.

## How this gets tested

### RTF Orchestrator

Used for everything behavioral: the router condition matrix, redaction, and troubleshoot.sh version coverage above.

#### What "environment" means for us

Each scenario is a `K8sEnvironment` that RTF deploys, with the degradation for that scenario pre-baked into its manifests rather than triggered live. An environment for this tool needs:

- A router Deployment and its ConfigMap, matching the official Apollo Helm chart or raw-manifest tier (see [Deployment tiers](#deployment-tiers)) — start with the official chart tier since it needs the least customer-supplied config, and add the raw-manifest tier once the base case works.
- The `router-diagnostics` chart's *rendered output* (`helm template`, not a live `helm install`, see the constraint below) included as one of the environment's manifests, for both `mode: local` and `mode: job`. That render is expected to already be known-good by the time it reaches here — see [Chart rendering across tiers and modes](#chart-rendering-across-tiers-and-modes) below for where its own correctness is checked.
- Per-scenario degradation (resource limits, a failing probe, a timed self-restart or memory-pressure entrypoint) expressed as manifest templating variables, driven by the Test Plan's `matrix` so each row in the [router condition matrix](#router-condition-matrix) is a matrix dimension value, not a distinct hand-maintained environment file.
- **The router's own container logs labeled `rtf.io/log-collection: "true"`.** This gets RTF to pull the *raw*, pre-redaction container logs into its own `output/logs/` alongside our tool's collected (redacted) bundle in the same run — see [Redaction verification technique](#redaction-verification-technique) below for why that matters.
- A router config (`router.yaml`) that exercises every custom redactor's trigger conditions, not a minimal one — see [Redaction](#redaction) above.

**Constraints:**

1. No live cluster access from the Scenario. The Scenario container has no kubeconfig and no cluster-API-capable ServiceAccount — only the `deploy-environment` step does (`crates/rtf-orchestrator/src/k8s/job.rs`). Degradation has to already be true of the environment by the time the Scenario starts, baked into the manifest as above rather than triggered live.

2. `K8sEnvironment` can't be run locally. A Kubernetes environment can be templated, checked, and resolved with the `rtf` CLI, but it can only be run via the Orchestrator.

#### Applying the router condition matrix to RTF

Most rows are just a matrix dimension value picked up by the templated manifest described above. A few cases need a specific note:

- **Some routers misbehaving:** two Deployments, `router-healthy` and `router-degraded`, both labeled `app.kubernetes.io/name=router` under one Service — the shared label is what makes the tool's selector and the Service see them as one fleet. `router-degraded` gets a failing `livenessProbe` (not the resource-throttling used for "routers under-resourced," so the two scenarios test different failure modes).

- **All routers misbehaving:** reuse the `router-degraded` config from "some routers misbehaving," applied to every replica instead of a minority — no `router-healthy` Deployment for this scenario.

- **Routers under-resourced:** verify by reading `node-metrics/*.json` and `router-metrics/result.json` against `resources.limits`, not `output_collection.prometheus`.

- **Router recently restarted** and **OOM in progress** both need their timing to live inside the pod's own entrypoint (a wrapper script, or a memory-ramping sidecar) rather than triggered externally. Don't assume a wrapper script's sleep interval lines up with Orchestrator provisioning time — this needs a throwaway RTF run to measure actual provisioning time before designing the timing. **TODO:** nothing in `rtf-morgue` does this kind of fault-injection timing (killing a process on a schedule, ramping memory) — its test plans are all steady-state load/perf/scalability/profiling.

#### Applying the collector attribution scenarios to RTF

Both are also just matrix dimension values on the same templated manifests, not separate environments:

- **Metrics/observability not configured** — the router manifest omits the Prometheus scrape annotations/exporter config for this dimension value.
- **RBAC permission declined** — the environment's Role manifest omits a specific permission (e.g. `nodes/proxy`) for this dimension value, rather than granting the full set every other row uses.

#### Redaction verification technique

- Point the spec's `redactUri` at a throwaway endpoint (verification runs only, never the shipped spec) to get troubleshoot.sh's per-redactor report. Where this endpoint actually lives, a sidecar in the environment, or something outside the cluster the environment can reach depends on **TODO:** what networking a `K8sEnvironment`'s namespace allows.

- Label the router service `rtf.io/log-collection: "true"` so RTF pulls its raw, pre-redaction logs alongside the redacted bundle in the same run, letting a known secret be diffed against both copies directly.

#### Collection mode and troubleshoot.sh version coverage in RTF

The floor and current-release versions are two separate environment variants, differing only in which `support-bundle` binary/image the environment stages.

#### Bundle retrieval in RTF

With job mode the Job already uploads the bundle to object storage on its own (`specs/deployment/v1/v1.md`). Point that upload at a throwaway test bucket, and have the Scenario poll it using object-storage credentials until the bundle appears, then download it. This also answers how the Scenario knows the Job is finished, since it has no way to check the Job's status directly.

### Other CI checks

Used for structural checks that don't need a real cluster.

#### Chart rendering across tiers and modes

Running `helm template` with each tier's (official chart, raw-manifest) and mode's (`local`, `job`) actual values, and validating the output.

#### Spec linting across troubleshoot.sh versions

Run `support-bundle lint` against the rendered spec once per troubleshoot.sh version in scope — a matrix of pinned `support-bundle` binaries (the declared floor, a current release), each linting the same rendered spec.
