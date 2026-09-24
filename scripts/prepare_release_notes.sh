#!/usr/bin/env bash
# Consumes .changeset/*.md files into this release's notes and deletes them.
#
# Usage: prepare_release_notes.sh <version>
#   <version> is the release tag, e.g. v1.2.3 — used only to name the output file.
#
# Run this as part of the version-bump PR (specs/release-process.md, step 4), not at tag
# time: the consumed changeset files must already be gone from the tree by the time the
# release is tagged. Writes the generated notes to .changeset/notes/<version>.md, committed
# alongside the version bump, and deletes every consumed .changeset/*.md file.

set -euo pipefail

VERSION="${1:?Usage: prepare_release_notes.sh <version>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CHANGESET_DIR="$REPO_ROOT/.changeset"
NOTES_DIR="$CHANGESET_DIR/notes"
NOTES_FILE="$NOTES_DIR/$VERSION.md"

mapfile -t CHANGESET_FILES < <(
  find "$CHANGESET_DIR" -maxdepth 1 -name '*.md' ! -name 'README.md' -print | sort
)

if [[ ${#CHANGESET_FILES[@]} -eq 0 ]]; then
  echo "Error: no changeset files found in $CHANGESET_DIR" >&2
  exit 1
fi

BREAKING=""
FEATURES=""
FIXES=""

for file in "${CHANGESET_FILES[@]}"; do
  CATEGORY=$(yq --front-matter=extract '.category' "$file" 2>/dev/null || true)
  IS_BREAKING=$(yq --front-matter=extract '.breaking' "$file" 2>/dev/null || true)

  # Extract the body after the frontmatter, trimming trailing whitespace per line
  # and leading blank lines.
  BODY=$(awk '/^---$/{c++; if(c==2){found=1; next}} found{print}' "$file" \
    | sed 's/[[:space:]]*$//' \
    | awk 'NF{body=1} body{print}')

  if [[ -z "$BODY" ]]; then
    continue
  fi

  # Format as a list item: first line as bullet, continuation lines indented.
  FORMATTED=$(printf '%s' "$BODY" | awk 'NR==1{print "- " $0; next} {print "  " $0}')

  if [[ "$IS_BREAKING" == "true" ]]; then
    BREAKING+="${FORMATTED}"$'\n\n'
  else
    case "$CATEGORY" in
      feat) FEATURES+="${FORMATTED}"$'\n\n' ;;
      fix) FIXES+="${FORMATTED}"$'\n\n' ;;
      # docs/ci/test are consumed but excluded from public release notes.
    esac
  fi
done

RELEASE_NOTES=""

if [[ -n "$BREAKING" ]]; then
  RELEASE_NOTES+="## ❗ BREAKING ❗"$'\n\n'"${BREAKING}"$'\n'
fi

if [[ -n "$FEATURES" ]]; then
  RELEASE_NOTES+="## 🚀 Features"$'\n\n'"${FEATURES}"$'\n'
fi

if [[ -n "$FIXES" ]]; then
  RELEASE_NOTES+="## 🐛 Fixes"$'\n\n'"${FIXES}"$'\n'
fi

RELEASE_NOTES=$(printf '%s' "$RELEASE_NOTES" | sed -e 's/[[:space:]]*$//')

if [[ -z "$RELEASE_NOTES" ]]; then
  echo "Error: every changeset was category docs/ci/test — nothing to publish as release notes." >&2
  exit 1
fi

mkdir -p "$NOTES_DIR"
printf '%s\n' "$RELEASE_NOTES" > "$NOTES_FILE"

for file in "${CHANGESET_FILES[@]}"; do
  rm "$file"
done

echo "Wrote $NOTES_FILE"
echo "${#CHANGESET_FILES[@]} changeset(s) consumed." >&2
