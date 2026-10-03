#!/usr/bin/env bash
# Shared assertion for specs/collection/data_sanitization/host_collector_diagnostics.md:
# the host `run` collector's <name>-info.json diagnostic sidecar is written unconditionally
# and it carries the *collecting machine's own* process environment. It must always be
# fully redacted.
#
# Usage: source this file, then call assert_host_collector_diagnostics_redacted <bundle-dir>
assert_host_collector_diagnostics_redacted() {
  local dir="$1"
  local info_file
  info_file=$(find "$dir/host-collectors/run-host" -maxdepth 1 -name "*-info.json" -type f 2>/dev/null | head -1)
  if [ -z "$info_file" ]; then
    echo "FAIL: no host-collector run diagnostic sidecar found under $dir/host-collectors/run-host - troubleshoot.sh's behavior here may have changed (expected unconditionally per pkg/collect/host_run.go)" >&2
    exit 1
  fi
  local content
  content=$(cat "$info_file")
  if [ "$content" != "***HIDDEN***" ]; then
    echo "FAIL: $info_file was not fully redacted (got: $content) - this file always contains the collecting machine's own environment" >&2
    exit 1
  fi
}
