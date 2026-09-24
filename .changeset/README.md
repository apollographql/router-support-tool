# Changesets

This directory tracks user-facing changes to the router support tool. Every PR that changes
customer-visible behavior should include a changeset file (enforced by CI).

## Creating a Changeset

**Interactive (recommended):**

```sh
mise run changeset
```

**Manual:**

Create a new Markdown file in this directory with a unique name (e.g. `fix-metrics-host-resolution.md`):

```markdown
---
category: fix
breaking: false
---

Fixed the raw-manifest tier's metrics host resolution under mode: job

`selector` wasn't being passed through to the metrics collector's host resolution, so
Prometheus scraping silently fell back to the wrong host.
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

| Category | Use for               | In release notes? |
| -------- | ---------------------- | ------------------ |
| `feat`   | New features          | Yes                |
| `fix`    | Bug fixes              | Yes                |
| `docs`   | Documentation changes  | No                  |
| `ci`     | CI/build changes       | No                  |
| `test`   | Test-only changes      | No                  |

There's no per-package bump-type field here (unlike `apollographql/operator`'s changesets) — this
repo's release version is chosen manually (see `specs/release-process.md`), not computed from
changesets.

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

There's no committed changelog file to maintain beyond that per-release notes snapshot — no
`CHANGELOG.md`, and category/breaking metadata isn't rendered anywhere public once consumed.

## Exemptions

- **Renovate PRs** are automatically exempted in CI.
- Apply the `skip-changeset` label for exceptional cases.
