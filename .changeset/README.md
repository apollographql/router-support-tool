# Changesets

This directory tracks user-facing changes to the router support tool. Every PR
should include a changeset file (enforced by CI).

## Creating a Changeset

**Interactive (recommended):**

```sh
mise run add-changeset
```

**Manual:**

Create a new Markdown file in this directory with a unique name (e.g. `add-metrics-port-value.md`):

```markdown
---
category: feat
breaking: false
---

Add metricsPort to configure the router's metrics port

Defaults to `9090`. Set this if your router's Prometheus exporter binds to a different port.
```

## File Format

### Frontmatter

```yaml
---
category: <category>
breaking: <true|false>
---
```

**Categories (required):**

| Category | Use for               | Release notes category     |
| -------- | ---------------------- | --------------------------|
| `feat`   | New features           | Features                  |
| `fix`    | Bug fixes              | Fixes                     |
| `docs`   | Documentation changes  | Maintenance               |
| `ci`     | CI/build changes       | Maintenance               |
| `test`   | Test-only changes      | Maintenance               |

**Breaking (required):**

| Value   | Use when                                                                                                       |
| ------- | --------------------------------------------------------------------------------------------------------------- |
| `true`  | The change breaks an existing customer-facing contract (chart values, `collect.sh` flags, collected bundle shape) |
| `false` | The change is backwards-compatible                                                                                |

Breaking changes appear in a dedicated section at the top of the release notes, regardless of
category.

### Description

Write it like a git commit message: a short summary line (becomes the release-notes bullet), then
an optional blank-line-separated body with more detail.

## How release notes are published

1. **Cutting a release** runs `scripts/prepare_release_notes.sh <version>` as part of the
   version-bump PR (`specs/release-process.md`, step 4). It reads every `.changeset/*.md` file,
   builds the categorized release notes, writes them to `.changeset/notes/<version>.md`, and
   deletes the consumed changeset files — all committed together in that PR.
2. When the release is tagged and published, the release workflow reads
   `.changeset/notes/<version>.md` from the tagged commit and sets it as the GitHub Release's
   notes, overwriting whatever was typed when the release was published.

## Exemptions

- **Renovate PRs** are automatically exempted in CI.
- Apply the `skip-changeset` label for exceptional cases.
