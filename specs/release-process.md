# Release Process

**One release, one version, published everywhere** — One GitHub Release, tagged `vX.Y.Z`,
publishes every artifact under that same version. The release version is the single number
that identifies "what a customer gets" across the image, the chart, and the collect script. See
`specs/artifact-distribution.md` for what each artifact is and where it's published.

**Cutting a release means choosing the troubleshoot.sh version it pins.** The pinned
`support-bundle` version the image and the script bundle is a deliberate choice made as part of
cutting that release.

**Release notes come from per-PR changesets** A PR that changes behavior adds a 
`.changeset/<name>.md` file (`category: feat|fix|docs|ci|test` plus `breaking: true|false`
frontmatter, enforced by CI — see `.changeset/README.md`).
At release-cut time, `scripts/prepare_release_notes.sh` consumes every
pending `.changeset/*.md` file into `.changeset/notes/vX.Y.Z.md` (breaking changes first,
regardless of category, then `feat` as Features, `fix` as Fixes, and `docs`/`ci`/`test` together
under a Maintenance heading — this repo is public, so every category is customer-visible) and
deletes the consumed files. The release workflow then reads that generated file from the tagged
commit and overwrites the GitHub Release's notes with it.

## How to cut a release

There's no `dev`/`main` split here — everything lives on `main`, unlike `apollographql/operator`'s
`dev` → `main` release flow this is modeled on. "Prepare" and "Finalize" below are both against
`main` directly.

1. **Verify CI is green on `main`** for the commit being released. This includes
   `run-rtf-test-plan.yaml`'s `build_job_image` job, which on every push to `main` builds the Job
   image and publishes it internally, keyed by commit SHA — that internal build is what gets
   republished to Docker Hub later, so it must have already succeeded for this commit.
2. **Confirm the troubleshoot.sh pin.** The Renovate-driven lock-step PR (Dockerfile ARG,
   `router-diagnostics-collect/collect.sh`'s own pin, chart's `troubleshoot_version`) should
   already be merged and tested.
3. **Choose the release version** (`vX.Y.Z`) — ordinary semver judgment about what changed.
4. **Run `.github/workflows/release_prepare.yaml`** via `workflow_dispatch`, passing
   `version: vX.Y.Z`. It bumps `router-diagnostics-chart/Chart.yaml`'s `version:` field and
   `router-diagnostics-chart/values.yaml`'s `job.image.tag`, regenerates Helm docs, runs
   `scripts/prepare_release_notes.sh vX.Y.Z` to consume pending `.changeset/*.md` files into
   `.changeset/notes/vX.Y.Z.md`, opens a **draft** GitHub Release with those notes for preview,
   and opens a PR (`release/vX.Y.Z`, labeled `release`) with all of that committed.
5. **Review and merge that PR normally**
6. **`.github/workflows/release_finalize.yaml` runs automatically**
   It publishes the draft Release, creates the `vX.Y.Z` tag, and calls `.github/workflows/release_publish_artifacts.yaml`
   directly as a job, which runs three sub-jobs in parallel:
   - `release_dockerhub` — republishes the already-built internal Job image to
     `docker.io/apollograph/router-diagnostics`, tagged `vX.Y.Z`.
   - `publish_helm_chart` — packages the chart from the tagged commit and publishes it to
     `oci://registry-1.docker.io/apollograph/router-diagnostics-chart`.
   - `attach_collect_script` — uploads `router-diagnostics-collect/collect.sh` from the tagged
     commit as a downloadable Release asset.

7. **Verify the actual published artifacts** — `docker pull` the image,
   `helm show chart oci://registry-1.docker.io/apollograph/router-diagnostics-chart
   --version vX.Y.Z`, and download the script through the customer-facing Orbiter URL.
   Confirm each reports the version expected.
8. **Update customer-facing docs** if anything customer-visible changed, and ensure public docs
   are updated.
