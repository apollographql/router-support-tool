# Testing

This directory holds two independent test mechanisms. They exist separately
because they cover different `mode`s and run in different places.

## Chainsaw integration tests for `mode:local`

[Chainsaw](https://kyverno.github.io/chainsaw/) tests that install `router-diagnostics-chart`
against a real Kubernetes cluster (a local [KinD](https://kind.sigs.k8s.io) cluster, or the one
`.github/workflows/collect-integration-test.yaml` spins up in CI) and assert on the actual
collected bundle — real collection, real redaction, not just a rendered spec.

- **`official-chart/`**, **`raw-manifest/`**, **`multi-release/`**, **`official-chart-metrics-no-servicemonitor/`**
  — one test directory per deployment-tier/scenario combination, each with its own
  `chainsaw-test.yaml`.
- **`scripts/`** — the `verify_*.sh` scripts each test's last step runs against the extracted
  bundle, plus shared helpers (`wait_for_metrics.sh`,
  `assert_host_collector_diagnostics_redacted.sh`) used by more than one of them.
- `fixtures/` — small shared fixtures the `chainsaw/` tests reference by relative path (for example `--set-file supergraphFile=../../fixtures/supergraph.graphql`).

### Running the Chainsaw tests
Run the following to execute our integration tests:

```bash
mise run kind-up        # creates a local KinD cluster named router-support-tool-test
mise run e2e-chainsaw   # runs every tier against it
mise run kind-down      # tear it down when you're done
```
Scope a run to one tier with `CHAINSAW_TEST_DIRS`:

```bash
CHAINSAW_TEST_DIRS=testing/chainsaw/raw-manifest mise run e2e-chainsaw
```

`mise run kind-up` reuses an existing cluster of the same name if one is already up — run
`mise run kind-down` first if you want a clean one.

### `kind-config.yaml`

The KinD cluster config `mise run kind-up` uses. Enables the `KubeletPSI` feature gate (off by
default) so the `nodeMetrics` collector can report `cpu.psi`/`memory.psi`. For details, go to
`specs/collection/base_spec.md`.

## RTF testing for `mode:job`

Everything `mode: job` needs is exercised separately, through
[RTF](https://github.com/apollographql/runtime-testing-framework) (the Apollo Runtime Testing
Framework) — an Apollo-internal service, not something you can run outside Apollo's own
infrastructure. `data/` holds the fixtures and scripts RTF's scenario runs:

- **`scenario.sh`** — installs `router-diagnostics-chart` with `mode: job`, runs collection,
  retrieves the uploaded bundle, and asserts on its contents (the `mode: job` counterpart to
  `chainsaw/scripts/verify_*.sh`).
- **`env_setup.sh`** — puts the router fixture into the condition a given test matrix variant
  needs before collection runs (healthy, a misconfigured metrics exporter, a recently-restarted
  pod).
- **`router-manifest.yaml`**, **`mock-backend-manifest.yaml`**, **`mock_backend_server.py`** —
  the router deployment and a mock upload receiver the Job uploads its bundle to.
  `*-router-config*.yaml`, `*-expected-redacted-router-config.yaml` — per-variant router config
  fixtures and the redacted output `scenario.sh` byte-diffs the collected config against.
  `supergraph.graphql` — the schema fixture for schema-collection coverage.

### `test-plan.yaml`

The RTF test plan definition itself: the condition/router-version matrix, and which files from
`data/` get provided to the environment vs. the scenario. `.github/workflows/run-rtf-test-plan.yaml`
is what actually triggers an RTF run of this plan.

## `spec-inventory-baseline.json`

The checked-in snapshot `mise run check-spec-inventory` diffs the rendered spec's collector and
redactor names/types/count against. Catches a collector or redactor being renamed, added, or
removed without updating this file in the same PR. Regenerate it with
`UPDATE_BASELINE=1 mise run check-spec-inventory` after a deliberate spec change.
