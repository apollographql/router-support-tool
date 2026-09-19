use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_bundle-verification"))
}

/// Writes `expected_values` (a serde_json::Value) to a temp file and returns its path.
fn write_expected_values(name: &str, expected_values: serde_json::Value) -> PathBuf {
    let path = std::env::temp_dir().join(format!("bundle-verification-test-{name}.json"));
    fs::write(
        &path,
        serde_json::to_string_pretty(&expected_values).unwrap(),
    )
    .expect("failed to write expected-values fixture");
    path
}

#[test]
fn raw_manifest_bundle_passes_every_check() {
    let dir = fixture("raw-manifest-bundle");
    let expected_values = write_expected_values(
        "raw-manifest-test",
        serde_json::json!({
            "image": "ghcr.io/apollographql/router:v2.16.3",
            "config_file": dir.join("expected-router-config.yaml"),
        }),
    );

    let output = Command::new(bin())
        .args([
            "--bundle-dir",
            dir.to_str().unwrap(),
            "--namespace",
            "test-ns",
            "--tier",
            "raw-manifest",
            "--expected-values",
            expected_values.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run bundle-verification");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "expected every check to pass, got:\n{stdout}"
    );
    assert!(stdout.contains("PASS  meta.json is accurate"));
    assert!(stdout.contains("PASS  router-metrics scraped real Prometheus output"));
    assert!(stdout.contains("PASS  clusterResources: pods are healthy"));
    assert!(stdout.contains("PASS  clusterResources: nodes are healthy"));
    assert!(stdout.contains("PASS  router-logs collected the router's startup log"));
    assert!(stdout.contains("PASS  APOLLO_KEY never appears in the bundle"));
    assert!(stdout.contains("PASS  nodeMetrics collected real kubelet data"));
    assert!(stdout.contains("PASS  configMap matches the real router config exactly"));
}

#[test]
fn official_chart_bundle_passes_every_check() {
    let dir = fixture("official-chart-bundle");
    let expected_values = write_expected_values(
        "official-chart-pass",
        serde_json::json!({ "graph_ref": "test-graph@test" }),
    );

    let output = Command::new(bin())
        .args([
            "--bundle-dir",
            dir.to_str().unwrap(),
            "--namespace",
            "test-ns",
            "--tier",
            "official-chart",
            "--expected-values",
            expected_values.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run bundle-verification");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "expected every check to pass, got:\n{stdout}"
    );
    assert!(stdout
        .contains("PASS  APOLLO_GRAPH_REF and APOLLO_ROUTER_OFFICIAL_HELM_CHART env vars present"));
    assert!(stdout.contains("PASS  configMap has the expected prometheus fields"));
    assert!(stdout.contains("PASS  nodeMetrics collected real kubelet data"));
}

/// --expected-values is optional - every field should fall back to its documented default
/// when the flag is not supplied.
#[test]
fn missing_required_field_fails_with_a_clear_message() {
    let dir = fixture("official-chart-bundle");
    let output = Command::new(bin())
        .args([
            "--bundle-dir",
            dir.to_str().unwrap(),
            "--namespace",
            "test-ns",
            "--tier",
            "official-chart",
            // no --expected-values. Since graph_ref has no default this should fail.
        ])
        .output()
        .expect("failed to run bundle-verification");

    assert!(
        !output.status.success(),
        "expected failure when graph_ref is missing"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("graph_ref"));
}

/// checks::pods_are_healthy filters an already-collected pods.json in-memory by
/// app.kubernetes.io/name=router. Without an explicit empty-match check, "all matched pods
/// are healthy" is vacuously true over an empty list, so the tool would PASS having
/// verified nothing - e.g. if the real router pod's label ever silently changed, or the
/// wrong namespace's pods.json got read. This fixture has only an unrelated pod (no
/// router-labeled one at all) to prove that empty match fails loudly instead.
#[test]
fn no_matching_pods_fails_instead_of_silently_passing() {
    let dir = fixture("no-matching-pods-bundle");
    let expected_values = write_expected_values(
        "no-matching-pods",
        serde_json::json!({ "graph_ref": "test-graph@test" }),
    );

    let output = Command::new(bin())
        .args([
            "--bundle-dir",
            dir.to_str().unwrap(),
            "--namespace",
            "test-ns",
            "--tier",
            "official-chart",
            "--expected-values",
            expected_values.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run bundle-verification");

    assert!(
        !output.status.success(),
        "expected failure when no pods match the expected label"
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("FAIL"));
    assert!(stdout.contains("no pods matched label"));
}

/// A mismatch in the config check should be identified and fail the test.
#[test]
fn config_mismatch_is_caught() {
    let dir = fixture("raw-manifest-bundle");
    let wrong_file: &Path = &dir.join("meta.json"); // any file with different content
    let expected_values = write_expected_values(
        "config-mismatch",
        serde_json::json!({
            "image": "ghcr.io/apollographql/router:v2.16.3",
            "config_file": wrong_file,
        }),
    );

    let output = Command::new(bin())
        .args([
            "--bundle-dir",
            dir.to_str().unwrap(),
            "--namespace",
            "test-ns",
            "--tier",
            "raw-manifest",
            "--expected-values",
            expected_values.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run bundle-verification");

    assert!(
        !output.status.success(),
        "expected failure on a config mismatch"
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("FAIL  configMap matches the real router config exactly"));
}
