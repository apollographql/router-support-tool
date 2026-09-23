# Router Support Tool

The Router Support Tool is a lightweight, external diagnostic tool that collects a sanitized snapshot of Apollo Router and Kubernetes cluster state — version, configuration, logs, metrics, and pod status — into a single bundle. Collection runs on demand, requires no router restart, and is safe to run against a degraded router.

Bundles stay in customer infrastructure. Sensitive data is redacted automatically before the bundle is written, and customers can inspect the contents before sharing anything with support.

Built on [troubleshoot.sh](https://troubleshoot.sh): this repository contains the SupportBundle spec defining what is collected, custom redactors for router-specific sensitive data, and the Helm chart that renders the spec into a cluster.

## Documentation

Design specifications live in [`specs/`](./specs). Start with [`specs/architecture.md`](./specs/architecture.md) — it defines the layer model the rest of the directory follows.

The architecture separates three concerns that vary independently:

| Layer | What varies |
| --- | --- |
| **Collection** | What data is collected, and how it is sanitized |
| **Trigger** | What causes a collection to happen |
| **Storage** | Where the resulting bundle lands |

Deployment — where collection runs, what permissions it needs, and how the customer deployed their router — is documented alongside these but is deliberately not a layer. See `architecture.md` for the reasoning.

```
specs/
├── architecture.md          # Layer model — start here
├── user_experience.md       # Customer-facing flows and invocation
├── collection/              # What is collected and how it is sanitized
├── trigger/                 # What causes collection to happen
├── storage/                 # Where bundles land
└── deployment/              # Execution location, RBAC, deployment tiers
```

## How specs work

Specifications in `specs/` describe current intended behavior. They are reviewed and merged like code — **a merged spec is an accepted decision.** Design changes go through a PR against the relevant spec, so review happens where the change is proposed rather than in a separate process.

Git history is the decision record. To understand why something is the way it is, read the PR that introduced it.

Where a design choice involved rejecting a viable alternative, the spec records it in a **Rejected alternatives** section — not as history, but because knowing what was ruled out and why is part of understanding the current design. If you are considering an approach listed there, engage with the recorded reasoning rather than re-proposing it.

## Local checks and git hooks

This repo uses [mise](https://mise.jdx.dev) tasks (`mise-tasks/`) as the single source of truth for its static checks — CI (`.github/workflows/static-checks.yaml`) and local [lefthook](https://lefthook.dev) hooks (`lefthook.yml`) both just call `mise run <task>`, so there's one place to fix a check rather than two. After cloning, install the hooks once:

```bash
mise install
mise exec -- lefthook install
```

`git commit` then runs the fast, local-only checks (`check-ghafmt`, `generate-helm-docs`, `helm-lint`) against whatever you changed, and `git push` additionally runs `spec-lint`, which needs the network (it downloads real `support-bundle` releases). CI runs all of them regardless, as the backstop for a skipped or bypassed hook.

## Helm chart documentation

`router-diagnostics-chart/README.md` is generated from `values.yaml`'s `# --` comments via [helm-docs](https://github.com/norwoodj/helm-docs). CI enforces it stays in sync (`fail-on-diff: true`) — after changing `router-diagnostics-chart/values.yaml`, regenerate it locally and commit the result:

```bash
mise run generate-helm-docs
```

## GitHub Actions workflow formatting

Workflow files under `.github/workflows/` are formatted with [ghafmt](https://github.com/jonathanrainer/ghafmt), and CI checks that they stay formatted. Before pushing a workflow change, check formatting locally:

```bash
mise run check-ghafmt
```

If it reports a diff, fix it in place:

```bash
docker run --rm -v "$(pwd)":/repo --workdir /repo ghcr.io/jonathanrainer/ghafmt:0.1.5 --mode=write .github/workflows/
```
