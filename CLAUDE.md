# Router Support Tool

An external diagnostic tool that collects a sanitized, point-in-time snapshot of Apollo Router and Kubernetes cluster state without requiring a router restart.

The tool is built on [troubleshoot.sh](https://troubleshoot.sh). **We author SupportBundle specs and custom redactors — we do not build collection, packaging, or redaction logic.** If a task seems to call for writing collection machinery, check whether troubleshoot.sh already provides it.

---

## Start here

Read `specs/architecture.md` before working on anything in this repo. It defines the layer model that the directory structure follows.

---

## Architecture in brief

Three layers, each varying independently:

- **Collection** — what data is collected, and how it is sanitized. The SupportBundle spec plus its redactors. Redaction is *part of this layer*, not separate: redactors live in the same spec YAML and version with it.
- **Trigger** — what causes a collection to happen. On-demand (v1); scheduled and threshold-triggered (v2).
- **Storage** — where the bundle lands. Local disk (v1); customer-provided S3/GCS (v2).

**Deployment is not a layer.** Where collection runs (local plugin vs. in-cluster Job/CronJob), RBAC, cluster footprint, and deployment tier are deployment concerns. Execution location adds no new capability — it is the same function relocated. See the reasoning in `specs/architecture.md`.

When adding new content, file it by which of these it changes. A change that touches two layers is a signal the boundary was drawn wrong — flag it rather than splitting the content.

---

## Repository layout

```
specs/
├── architecture.md          # Layer model. Required reading.
├── user_experience.md       # Customer-facing flows and invocation
├── collection/              # What is collected and how it is sanitized
├── trigger/                 # What causes collection to happen
├── storage/                 # Where bundles land
└── deployment/              # Execution location, RBAC, deployment tiers
```

---

## How specs work

Specs describe current intended behavior. They are reviewed and merged like code — **a merged spec is an accepted decision.** Design changes go through a PR against the relevant spec.

**The specs are the source of truth for intended behavior, and they must stay current.** A spec is not a historical proposal or a design sketch — it describes what the implementation is supposed to do right now. Consequences:

- **Spec first.** A behavior change starts as a spec change. Update the spec, then implement against it — not the other way round.
- **Reconcile, don't diverge.** If an implementation change is already in hand and the spec does not describe it, the change is not done until the spec is updated in the same PR. "The code does X but the spec says Y" is a defect in one of the two, never an acceptable steady state.
- **Divergence is a bug — report it.** If you find implementation and spec disagreeing, say so explicitly and ask which one is correct rather than assuming the code is authoritative and quietly editing the spec to match.
- **Never infer intended behavior from the implementation alone.** When answering a question about how the tool is supposed to behave, the spec is the answer. The code is evidence about what was built, not about what was intended.

Git history is the decision record. To understand why something is the way it is, read the PR that introduced it. Do not create parallel decision-log files; the reasoning belongs in the PR, and the outcome belongs in the spec.

**Where a spec has a "Rejected alternatives" section, treat it as binding.** Those approaches were evaluated and ruled out, and the reasoning is recorded because knowing what was rejected is part of understanding the current design. If a task points toward one of them, engage with the recorded reasoning rather than re-proposing the approach.

When a design question arises that the specs do not answer, propose a spec change in a PR rather than deciding silently in an implementation. If the choice involved rejecting a viable alternative, add it to that spec's Rejected alternatives section in the same PR.

---

## Constraints that are easy to get wrong

These are load-bearing. Violating any of them is a correctness problem, not a style preference.

- **`APOLLO_KEY` is never collected.** Not redacted — never read. It is structurally isolated in a separate Kubernetes Secret from the ConfigMap the tool reads. No redaction rule should be load-bearing for it.
- **Empty is not failure.** A collector whose target does not exist (Prometheus disabled, no Redis configured, no matching ConfigMap) returns empty and the run continues. Collection degrades gracefully; `meta.json` records what ran so an empty section is explainable.
- **The tool must be safe to run against a degraded router.** Collection gathers signal externally wherever possible — k8s API, cAdvisor, external HTTP endpoints. Anything that runs *inside* the router container consumes its cgroup allocation and needs justification.
- **`exec` collectors only run against one pod.** troubleshoot.sh's `exec` collector executes in a single arbitrarily-selected pod when a selector matches several. It is not fleet-wide. `logs` does not have this limitation.
- **Bundles never go to Apollo.** Storage is customer-owned. Apollo has access only when a customer explicitly shares a bundle during a support engagement.
- **v1 is Kubernetes-only.** ECS, Fargate, and standalone VM deployments are out of scope.
- **v1 ships one spec, on-demand only.** Additional specs and automated triggers are later milestones. Do not assume they exist.

---

## Working in this repo

- Specs are YAML consumed by troubleshoot.sh. Validate changes against the collector documentation at https://troubleshoot.sh/docs/collect/ rather than assuming a field exists.
- Customer-supplied values (namespace, selector, ConfigMap name) cannot be passed as CLI flags — troubleshoot.sh takes spec *sources*, not collector parameters. Values reach the spec via the Helm chart.