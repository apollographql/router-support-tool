# On Demand Collection (v1 and v2)

What v1 and v2 of the Router Support Tool is, and what it deliberately is not.

v1/2 deliver **one spec, collected on demand, stored wherever the customer runs it.** Kubernetes only. Scheduled and threshold-triggered collection are v2 (`specs/trigger/`).

Detail lives with the layer it belongs to:

| Area | Spec |
| --- | --- |
| What is collected, and how it is sanitized | `specs/collection/base_spec.md` |
| Collector naming | `specs/collection/collector_naming.md` |
| Bundle self-description | `specs/collection/meta_json.md` |
| Bundle output | `specs/collection/output.md` |
| Chart, tiers, RBAC, execution location | `specs/deployment/on-demand-collection.md` |
| Customer-facing flows | `specs/user_experience.md`|
| Storage | `specs/storage/object_storage.md` |
| Apollo Operator specifics | Coming soon |

---

## Supported router versions

Apollo Router **2.4.0 through 3.0.0 preview** (`v3.0.0-preview.0`) are supported. The versions the RTF plan runs against are the evidence: 2.4.0, 2.10.1, 2.13.0, 2.17.0, 2.19.0, and 3.0 preview, listed in `testing/test-plan.yaml`. The plan is the source of truth for what is tested, so a version bump there is a version-support change and updates this section.

What this does **not** claim:

- Versions older than 2.4.0 are untested.
- Versions between the tested ones (for example 2.5 through 2.9) are covered only by being between versions that pass. They are not run individually.
- The 3.0 preview is a pre-release. Support for it means the tested preview behaves correctly, not that later 3.0 preview or release builds are verified until the plan is updated (Renovate proposes the preview pin bump).
- A redactor targets a config field that exists only in some versions (for example `response_cache`, which only newer routers have), and has nothing to match on versions without it. That is not a gap.

## Use of troubleshoot.sh

The tool is built on [troubleshoot.sh](https://troubleshoot.sh), an open-source Kubernetes diagnostics project maintained by Replicated. **We do not build collection, packaging, or redaction machinery.** What we author is a SupportBundle spec — a YAML declaration of which of their collectors to run, against which targets, with which redactors — plus the Helm chart that delivers it and the Job image that can run it.

Useful entry points into their documentation:

| For | Link |
| --- | --- |
| Project overview | https://troubleshoot.sh |
| Installing the `support-bundle` plugin | https://troubleshoot.sh/docs/#installation |
| Collecting a bundle, and spec sources | https://troubleshoot.sh/docs/support-bundle/collecting/ |
| Discovering specs already in the cluster | https://troubleshoot.sh/docs/support-bundle/discover-cluster-specs/ |
| Collector reference — validate every field against this | https://troubleshoot.sh/docs/collect/ |
| Redactor reference | https://troubleshoot.sh/docs/redact/ |
| Analyzer reference (**not used in v1**, see below) | https://troubleshoot.sh/docs/analyze/ |

A SupportBundle spec has three parts. v1 uses two of them:

| Part | v1 | What it does |
| --- | --- | --- |
| **Collectors** | **Used** | Gather data — pods, logs, config, kubelet metrics, HTTP endpoints |
| **Redactors** | **Used** | Strip sensitive values after collection, before packaging. Their built-ins plus Apollo's custom rules |
| **Analyzers** | **Not used** | Evaluate collected data and emit pass/warn/fail findings |

Validate any field against the collector reference above rather than assuming it exists.

### Analyzers are out of scope for v1

troubleshoot.sh supports [analyzers](https://troubleshoot.sh/docs/analyze/): declarative rules that read what the collectors gathered and emit a pass, warn, or fail result. A `clusterResource` analyzer could, for instance, read the collected pod JSON and state outright *"router pod X was OOM-killed, 4 restarts"* rather than leaving support to find `lastState.terminated.reason` themselves.

**v1 ships no analyzers.** This is a deliberate scope decision, not an oversight.

The reasoning:

- **v1's job is to get the routine data into support's hands, not to diagnose.**
- **Analyzers are a second body of authored content with its own review burden.** Each one encodes a diagnostic opinion — what counts as too many restarts, which log line indicates a real fault — and a wrong or stale opinion is worse than none, because it tells a support engineer something confident and incorrect. That warrants its own review cycle rather than riding along with v1.
- **Nothing about deferring them is costly.** Analyzers read data that is already in the bundle. Adding them later requires no change to what is collected, no new permissions, and no change to the chart — so there is no compounding cost to waiting, and no rework created by it.

**What this means in practice:** a v1 bundle is raw material. It answers "what was the state of this router".

## Storage

Only customer-provided object storage (`specs/storage/object_storage.md`) is in scope for v1, and only for `mode: job`. `mode: local` needs nothing from this tool to reach object storage: the bundle already lands as a plain file the customer holds and they can push it wherever they like with their own tooling.
