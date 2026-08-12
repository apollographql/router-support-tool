# Router Support Tool

An external diagnostic tool that collects a sanitized, point-in-time snapshot of Apollo Router and Kubernetes cluster state without requiring a router restart.

The tool is built on [troubleshoot.sh](https://troubleshoot.sh). **We author SupportBundle specs and custom redactors — we do not build collection, packaging, or redaction logic.** If a task seems to call for writing collection machinery, check whether troubleshoot.sh already provides it. v1 uses their collectors and redactors only; **analyzers are out of scope** — see `specs/versions/v1.md`.

What's ours to build is everything *around* their engine:

- How the spec reaches a cluster
- How collection is triggered
- How a bundle is stored
- How redaction preferences are exposed to the customer

---

## Start here

Read `specs/architecture.md` before working on anything in this repo. It defines the layer model that the directory structure follows.

Then read the version file for the milestone you are working on — `specs/versions/v1.md` for v1. The architecture describes the design across versions; the version file is what says which parts of it are actually in scope now.

---

## Architecture in brief

Three layers, each varying independently:

- **Collection** — what data is collected, and how it is sanitized. The SupportBundle spec plus its redactors. Redaction is *part of this layer*, not separate: redactors live in the same spec YAML and version with it.
- **Trigger** — what causes a collection to happen. On-demand (v1); scheduled and threshold-triggered (v2).
- **Storage** — where the bundle lands. Local disk (v1); customer-provided S3/GCS (v2).

**Deployment is not a layer.** Where collection runs (local plugin vs. in-cluster Job/CronJob), RBAC, cluster footprint, and deployment tier are deployment concerns. Execution location adds no new capability — it is the same function relocated. See the reasoning in `specs/architecture.md`.

**The test for whether something is a layer or a deployment concern (or any other non-layer concept): can the system's behavior be fully described without reference to it?** *"On threshold crossing, collect the base spec, write to object storage"* is a complete description — where the process happens to run never comes up, so execution location isn't a layer. Contrast storage, where *"the bundle goes somewhere"* leaves a genuine open question that has to be answered. Apply this test before proposing a new layer or arguing an existing boundary is wrong.

When adding new content, file it by which of these it changes. A change that touches two layers is a signal the boundary was drawn wrong — flag it rather than splitting the content.

---

## Repository layout

```
specs/
├── architecture.md          # Layer model. Required reading.
├── user_experience.md       # Customer-facing flows and invocation
├── versions/                # What each version ships, and what it deliberately does not
├── collection/              # What is collected and how it is sanitized
├── trigger/                 # What causes collection to happen
├── storage/                 # Where bundles land
└── deployment/              # Execution location, RBAC, deployment tiers
```

### `specs/versions/` — start here for anything version-specific

**Every version of the tool has exactly one file in `specs/versions/`, and that file is the authority on what that version ships.** v1 is `specs/versions/v1.md`; v2 gets `specs/versions/v2.md`, and so on.

Read the relevant version file before answering "does the tool do X?" — the layer specs describe designs across versions, so they will happily describe a v2 trigger or a future spec as though it exists. The version file is what says whether a capability is actually in the milestone you are being asked about. `specs/versions/v1.md` also records our use of troubleshoot.sh — which parts of the engine v1 uses, and that analyzers are out of scope.

When a new version is planned, create its file in this directory first. It states what the version ships, what it deliberately excludes, and where the detail lives; the layer specs then carry the detail. A version file that only lists inclusions is incomplete — **the exclusions are the more useful half**, because they are what stops a later reader assuming a capability exists.

---

## How specs work

Specs describe current intended behavior. They are reviewed and merged like code — **a merged spec is an accepted decision.** Design changes go through a PR against the relevant spec.

**The specs are the source of truth for intended behavior, and they must stay current.** A spec is not a historical proposal or a design sketch — it describes what the implementation is supposed to do right now. Consequences:

- **Spec first.** A behavior change starts as a spec change. Update the spec, then implement against it — not the other way round.
- **Reconcile, don't diverge.** If an implementation change is already in hand and the spec does not describe it, the change is not done until the spec is updated in the same PR. "The code does X but the spec says Y" is a defect in one of the two, never an acceptable steady state.
- **Before considering an edit to a cross-referenced fact complete, grep `specs/` for every place that references it.** A fact stated in one file and pointed to from others has drifted before — check every pointer, not just the file you edited.
- **Divergence is a bug — report it.** If you find implementation and spec disagreeing, say so explicitly and ask which one is correct rather than assuming the code is authoritative and quietly editing the spec to match.
- **Never infer intended behavior from the implementation alone.** When answering a question about how the tool is supposed to behave, the spec is the answer. The code is evidence about what was built, not about what was intended.

Git history is the decision record. To understand why something is the way it is, read the PR that introduced it. Do not create parallel decision-log files; the reasoning belongs in the PR, and the outcome belongs in the spec.

**Where a spec has a "Rejected alternatives" section, treat it as binding.** Those approaches were evaluated and ruled out, and the reasoning is recorded because knowing what was rejected is part of understanding the current design. If a task points toward one of them, engage with the recorded reasoning rather than re-proposing the approach.

When a design question arises that the specs do not answer, propose a spec change in a PR rather than deciding silently in an implementation. If the choice involved rejecting a viable alternative, add it to that spec's Rejected alternatives section in the same PR.

---

## Constraints that are easy to get wrong

These are load-bearing. Violating any of them is a correctness problem, not a style preference.

- **`APOLLO_KEY` is never collected.** Not redacted — never read. It is structurally isolated in a separate Kubernetes Secret from the ConfigMap the tool reads. No redaction rule should be load-bearing for it.
- **Empty is not failure.** A collector whose target does not exist (Prometheus disabled, no matching ConfigMap, no locatable Helm release) returns empty and the run continues. Collection degrades gracefully; `meta.json` records which absences are *expected* (it is static, baked in at render time — it cannot report what actually ran) so an empty section is explainable rather than mysterious.
- **The tool must be safe to run against a degraded router.** Collection gathers signal externally wherever possible — k8s API, cAdvisor, external HTTP endpoints. Anything that runs *inside* the router container consumes its cgroup allocation and needs justification.
- **`exec` collectors only run against one pod.** troubleshoot.sh's `exec` collector executes in a single arbitrarily-selected pod when a selector matches several. It is not fleet-wide; `logs` does not have this limitation.
- **Bundles never go to Apollo.** Storage is customer-owned. Apollo has access only when a customer explicitly shares a bundle during a support engagement.
- **v1 is Kubernetes-only.** ECS, Fargate, and standalone VM deployments are out of scope.
- **v1 ships one spec, on-demand only.** Additional specs and automated triggers are later milestones. Do not assume they exist. `specs/versions/v1.md` is the authority on v1's scope — check it before assuming a capability is present.

---

## Testing and verification

**Verification carries at least as much weight here as implementation, and treating it as a follow-up task is the single easiest way to ship something that looks finished and isn't.**

The reason is structural. We author specs, not collection code — troubleshoot.sh already runs. So "the implementation" is a few hundred lines of YAML that will always *parse*, always produce a `.tar.gz`, and always look successful. Whether it collected the right signal, from the right pods, with sanitization actually applied, is not visible from the artifact. Only a run against a realistic cluster shows that. A spec that has never been executed against a real router is an untested hypothesis, however carefully reviewed.

**The degraded case is the one that matters most.** A support bundle is often collected precisely when something is wrong, so verifying only against a healthy router validates the tool in only one condition. "Safe to run against a degraded router" is a claim in `specs/architecture.md`, and a claim is not evidence — it has to be demonstrated under real memory pressure, not reasoned about.

### The verification matrix

Scenarios to validate against. Not exhaustive — add cases as failure modes are found:

- **All routers healthy** — baseline. Everything expected is collected, redaction runs, `meta.json` is accurate.
- **Some routers misbehaving** — the affected pods are collected, and healthy neighbors are unaffected by collection running against degraded ones.
- **All routers misbehaving** — the "safe to run at any time" claim holds under genuinely degraded conditions, and a bundle is still produced even when some collectors return empty.
- **Routers under-resourced** — the negligible-resource-consumption claim holds when the container is already near its CPU or memory cgroup limit. This is where an in-container collector does damage if one is ever added.
- **Router recently restarted** — previous-container logs are captured (the `logs` collector always requests them, writing `<name>-previous.log`) and startup errors appear in the bundle.
- **OOM in progress** — for v2, that danger-zone suppression works and the tool does not trigger collection that would worsen the situation.

### What every run must confirm, not just the happy path

- **A bundle is produced even when collectors return empty.** Empty is not failure; a failed run is. Verify the distinction actually holds rather than assuming graceful degradation.
- **Every empty section is empty for a known, named reason.** This is the sharper half of "empty is not failure," and the easier half to get wrong. Graceful degradation means a mis-targeted collector and a legitimately absent target produce *the same output*: nothing. So an empty section is not self-explanatory — it is either expected absence (Prometheus not enabled, no matching ConfigMap, tier without that capability) or a defect wearing the same clothes. Attribute each one. If you cannot say why a section is empty, treat it as a failure until you can, rather than reading it as graceful degradation working correctly.
  - The defects that hide here are the ordinary ones: wrong namespace, or a namespace falling back to the kubectl context; a selector or label that does not match; a ConfigMap name that does not exist; a metrics port that differs from the spec's default, or an exporter bound to loopback; RBAC declined or never granted.
  - **Test positive controls, not just graceful ones.** For every collector, run at least one scenario where the target definitely *does* exist and assert the section is populated with plausible content. A spec where every collector silently returns empty passes a "the bundle was produced" check perfectly and is worth nothing to support. That is the failure this repo is most likely to ship, because it looks identical to success.
  - When absence *is* expected, `meta.json` is what records it — which is why the accuracy requirement below is load-bearing rather than cosmetic.
- **Redaction ran.** Inspect the bundle contents. Redaction is the promise with the worst failure mode — a leak is unrecoverable once shared — and it is the one thing a customer cannot check on our behalf before sending.
- **`meta.json` is accurate.** It is what makes an empty section explainable instead of mysterious, and what makes healthy-versus-incident bundle comparison possible. Wrong metadata is worse than absent metadata.
- **`APOLLO_KEY` is absent.** Every scenario, every tier.

### Collection engine version

The engine is not ours to pin on the local paths — the customer installs the `support-bundle` binary themselves and `krew` installs latest, so only the `mode: job` image pins a version. Testing is therefore the only control available:

- **Test the declared floor and a current release.** Drift cuts both ways: a plugin *older* than expected may not support a field the spec uses, and one *newer* than anything tested may change behavior or default redaction. The newer direction is unbounded, because `krew` moves on its own schedule.
- **The declared minimum version comes from a verified run, never a guess.** If no run has established it, it is unknown — say so rather than picking a plausible number.
- **Verify what an older plugin does with an unrecognized field** — hard error or silent ignore. A hard error is tolerable, since the customer sees it. A silent ignore means a quietly incomplete bundle nobody knows to question, which is the failure mode worth engineering against.
- The `mode: job` image pins the engine, which makes it the reproducible path. Prefer it when a test needs a known-good collection.
- **When a bundle looks wrong, check `version.yaml` first.** Every bundle carries it, written by troubleshoot.sh with the version that produced it — so the engine version behind any bundle is always knowable without asking the customer. Compare it against the declared floor in `meta.json`.

See `specs/deployment/v1/v1.md` → Collection engine version for the requirements this implements.

---

## Working in this repo

- Specs are YAML consumed by troubleshoot.sh. Validate changes against the collector documentation at https://troubleshoot.sh/docs/collect/ rather than assuming a field exists.
- **Adopting a collector or field that raises the minimum supported troubleshoot.sh version is a deliberate, reviewed change — call it out explicitly in the PR.** The collection engine is not ours to pin: for local invocation the customer supplies the `support-bundle` binary themselves and krew installs latest, so a spec field newer than their plugin fails on their machine, not ours. Treating a raised minimum as a normal edit is how an ambient compatibility risk becomes a silent one; treating it as a change-control step is the whole mitigation. See [Collection engine version](#collection-engine-version) above for what that requires in testing.
- Customer-supplied values (namespace, selector, ConfigMap name) cannot be passed as CLI flags — troubleshoot.sh takes spec *sources*, not collector parameters. Values reach the spec via the Helm chart.
