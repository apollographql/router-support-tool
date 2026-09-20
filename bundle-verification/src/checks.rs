use anyhow::{anyhow, Context, Result};
use serde_json::Value;
use std::fs;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

pub type CheckResult = Result<()>;

fn read_json(path: &Path) -> Result<Value> {
    let raw = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    serde_json::from_str(&raw).with_context(|| format!("parsing JSON from {}", path.display()))
}

/// Check meta.json's render-time facts, see specs/collection/meta_json.md.
pub fn meta_json_is_accurate(bundle_dir: &Path, namespace: &str, mode: &str) -> CheckResult {
    let meta = read_json(&bundle_dir.join("meta.json"))?;
    let actual_mode = meta["mode"].as_str().unwrap_or_default();
    let actual_ns = meta["namespace"].as_str().unwrap_or_default();
    if actual_mode != mode {
        return Err(anyhow!(
            "meta.json mode = {actual_mode:?}, expected {mode:?}"
        ));
    }
    if actual_ns != namespace {
        return Err(anyhow!(
            "meta.json namespace = {actual_ns:?}, expected {namespace:?}"
        ));
    }
    Ok(())
}

/// Check router-metrics/result.json (from the http collector)
pub fn router_metrics_has_real_scrape(bundle_dir: &Path) -> CheckResult {
    let result = read_json(&bundle_dir.join("router-metrics/result.json"))?;
    let status = result["response"]["status"].as_i64();
    let body = result["response"]["body"].as_str().unwrap_or_default();
    if status != Some(200) {
        return Err(anyhow!(
            "router-metrics/result.json: expected response.status == 200, got {:?} (full: {})",
            status,
            result
        ));
    }
    // Check we get actual metrics
    if !body.contains("apollo_router_") {
        return Err(anyhow!(
            "router-metrics/result.json: response.body doesn't contain \"apollo_router_\" - \
                 got a real 200 but not real router metrics text"
        ));
    }
    Ok(())
}

/// Check node-metrics/*.json (generated from the nodeMetrics collector)
pub fn node_metrics_has_real_kubelet_data(bundle_dir: &Path) -> CheckResult {
    let dir = bundle_dir.join("node-metrics");

    let read_dir = fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))?;

    let mut saw_router_container = false;
    let mut files_processed = 0;

    for entry in read_dir.flatten() {
        let path = entry.path();
        // The support bundle generates a json file
        if path.extension().is_none_or(|ext| ext != "json") {
            continue;
        }
        files_processed += 1;

        let doc = read_json(&path)?;
        if let Some(pods) = doc["pods"].as_array() {
            for pod in pods {
                if let Some(containers) = pod["containers"].as_array() {
                    for container in containers {
                        if container["name"].as_str() != Some("router") {
                            continue;
                        }
                        saw_router_container = true;

                        let file_str = path.display();
                        // Check all expected data is present
                        for (field, val) in [
                            (
                                "memory.workingSetBytes",
                                &container["memory"]["workingSetBytes"],
                            ),
                            ("memory.rssBytes", &container["memory"]["rssBytes"]),
                            ("memory.usageBytes", &container["memory"]["usageBytes"]),
                            ("memory.pageFaults", &container["memory"]["pageFaults"]),
                            (
                                "memory.majorPageFaults",
                                &container["memory"]["majorPageFaults"],
                            ),
                            ("cpu.usageNanoCores", &container["cpu"]["usageNanoCores"]),
                            (
                                "cpu.usageCoreNanoSeconds",
                                &container["cpu"]["usageCoreNanoSeconds"],
                            ),
                            // Requires the KubeletPSI feature gate - see
                            // .github/testdata/kind-config.yaml.
                            ("cpu.psi", &container["cpu"]["psi"]),
                            ("memory.psi", &container["memory"]["psi"]),
                        ] {
                            if val.is_null() {
                                return Err(anyhow!(
                                    "node-metrics: router container's {field} is missing in {file_str}"
                                ));
                            }
                        }
                    }
                }
            }
        }

        if doc["node"]["memory"]["availableBytes"].is_null() {
            return Err(anyhow!(
                "node-metrics: node.memory.availableBytes is missing in {}",
                path.display()
            ));
        }
    }

    if files_processed == 0 {
        return Err(anyhow!("no *.json files under {}", dir.display()));
    }

    if !saw_router_container {
        return Err(anyhow!(
            "no container named \"router\" found in any node-metrics/*.json"
        ));
    }

    Ok(())
}

/// Check clusterResources collector: pod status, restart counts, resources,
/// and (optionally) image tag for every pod matching the given label.
/// Empty label matches are treated as a failure for our testing.
/// Supplying a wrong label/selector to the test (causing no data to be included in the bundle)
/// causes this test to fail.
pub fn pods_are_healthy(
    bundle_dir: &Path,
    namespace: &str,
    label_key: &str,
    label_value: &str,
    expected_image: Option<&str>,
    expected_resources: &ExpectedResources,
) -> CheckResult {
    let path = bundle_dir
        .join("cluster-resources/pods")
        .join(format!("{namespace}.json"));
    let doc = read_json(&path)?;

    let items = doc["items"].as_array().map(|v| v.as_slice()).unwrap_or(&[]);
    let mut matched_any_pods = false;

    for pod in items {
        // Filter by label
        if pod["metadata"]["labels"][label_key].as_str() != Some(label_value) {
            continue;
        }
        matched_any_pods = true;

        let name = pod["metadata"]["name"].as_str().unwrap_or("<unknown>");
        let phase = pod["status"]["phase"].as_str().unwrap_or_default();
        if phase != "Running" {
            return Err(anyhow!(
                "pod {name}: status.phase = {phase:?}, expected \"Running\""
            ));
        }

        let restart_count = pod["status"]["containerStatuses"]
            .get(0)
            .and_then(|status| status["restartCount"].as_i64());

        if restart_count != Some(0) {
            return Err(anyhow!(
                "pod {name}: restartCount = {restart_count:?}, expected 0"
            ));
        }

        let container = match pod["spec"]["containers"].get(0) {
            Some(c) => c,
            None => return Err(anyhow!("pod {name}: has no containers specified")),
        };

        if let Some(image) = expected_image {
            let actual = container["image"].as_str().unwrap_or_default();
            if actual != image {
                return Err(anyhow!(
                    "pod {name}: image = {actual:?}, expected {image:?}"
                ));
            }
        }

        let resources = &container["resources"];
        expected_resources.check(name, resources)?;
    }

    if !matched_any_pods {
        return Err(anyhow!(
            "no pods matched label {label_key}={label_value} in {}",
            path.display()
        ));
    }

    Ok(())
}

#[derive(serde::Deserialize)]
#[serde(default)]
pub struct ExpectedResources {
    pub requests_cpu: String,
    pub requests_memory: String,
    pub limits_cpu: String,
    pub limits_memory: String,
}

impl Default for ExpectedResources {
    fn default() -> Self {
        Self {
            requests_cpu: "100m".to_string(),
            requests_memory: "128Mi".to_string(),
            limits_cpu: "500m".to_string(),
            limits_memory: "256Mi".to_string(),
        }
    }
}

impl ExpectedResources {
    fn check(&self, pod_name: &str, resources: &Value) -> Result<()> {
        let checks = [
            ("requests.cpu", "requests", "cpu", &self.requests_cpu),
            (
                "requests.memory",
                "requests",
                "memory",
                &self.requests_memory,
            ),
            ("limits.cpu", "limits", "cpu", &self.limits_cpu),
            ("limits.memory", "limits", "memory", &self.limits_memory),
        ];
        for (label, group, key, expected) in checks {
            let actual = resources[group][key].as_str().unwrap_or_default();
            if actual != expected.as_str() {
                return Err(anyhow!(
                    "pod {pod_name}: resources.{label} = {actual:?}, expected {expected:?}"
                ));
            }
        }
        Ok(())
    }
}

/// Check clusterResources: node MemoryPressure/DiskPressure conditions.
/// Nodes aren't namespace-scoped, so this file always carries every node in the cluster.
pub fn nodes_are_healthy(bundle_dir: &Path) -> CheckResult {
    let doc = read_json(&bundle_dir.join("cluster-resources/nodes.json"))?;
    let nodes = doc["items"].as_array().map(|v| v.as_slice()).unwrap_or(&[]);

    for condition_type in ["MemoryPressure", "DiskPressure"] {
        let mut found_any = false;
        let mut condition_triggered = false;
        let mut triggered_statuses = Vec::new();

        for node in nodes {
            if let Some(conditions) = node["status"]["conditions"].as_array() {
                for c in conditions {
                    if c["type"].as_str() == Some(condition_type) {
                        found_any = true;
                        let status = c["status"].as_str().unwrap_or_default();

                        if status != "False" {
                            condition_triggered = true;
                            triggered_statuses.push(status.to_string());
                        }
                    }
                }
            }
        }

        if !found_any {
            return Err(anyhow!("no {condition_type} condition found on any node"));
        }

        if condition_triggered {
            return Err(anyhow!(
                "{condition_type} condition(s) not all \"False\": {triggered_statuses:?}"
            ));
        }
    }

    Ok(())
}

/// Check router-logs/*/router.log
pub fn router_logs_contains_expected_content(
    bundle_dir: &Path,
    expected_content: &str,
) -> CheckResult {
    let dir = bundle_dir.join("router-logs");
    let pod_dirs: Vec<_> = fs::read_dir(&dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .collect();

    for pod_dir in &pod_dirs {
        let log_path = pod_dir.path().join("router.log");
        let Ok(content) = fs::read_to_string(&log_path) else {
            continue;
        };
        for line in content.lines() {
            if let Ok(entry) = serde_json::from_str::<Value>(line) {
                if entry["target"].as_str() == Some(expected_content) {
                    return Ok(());
                }
            }
        }
    }
    Err(anyhow!(
        "no router.log under {} contained a line with target == {expected_content:?}",
        dir.display()
    ))
}

fn search_directory(dir: &Path, content: &str) -> Result<Option<PathBuf>> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_dir() {
            if let Some(found_path) = search_directory(&path, content)? {
                return Ok(Some(found_path));
            }
        } else {
            let Ok(file) = File::open(&path) else {
                continue;
            };

            let mut reader = BufReader::new(file);
            let mut line = String::new();

            while reader.read_line(&mut line).unwrap_or(0) > 0 {
                if line.contains(content) {
                    return Ok(Some(path));
                }
                line.clear();
            }
        }
    }
    Ok(None)
}

/// APOLLO_KEY must never be collected
pub fn apollo_key_never_appears(bundle_dir: &Path) -> CheckResult {
    if let Some(offending_path) = search_directory(bundle_dir, "APOLLO_KEY")? {
        return Err(anyhow!(
            "APOLLO_KEY found in bundle contents: {:?}",
            offending_path.display()
        ));
    }

    Ok(())
}

/// Check clusterResources: APOLLO_GRAPH_REF/APOLLO_ROUTER_OFFICIAL_HELM_CHART env vars
/// Only the official Apollo router Helm chart are guaranteed to set these.
pub fn official_chart_env_vars_present(
    bundle_dir: &Path,
    namespace: &str,
    label_key: &str,
    label_value: &str,
    expected_graph_ref: &str,
) -> CheckResult {
    let path = bundle_dir
        .join("cluster-resources/pods")
        .join(format!("{namespace}.json"));
    let doc = read_json(&path)?;

    let items = doc["items"].as_array().map(|v| v.as_slice()).unwrap_or(&[]);
    let mut matched_any_pods = false;

    for pod in items {
        if pod["metadata"]["labels"][label_key].as_str() != Some(label_value) {
            continue;
        }
        matched_any_pods = true;

        let name = pod["metadata"]["name"].as_str().unwrap_or("<unknown>");
        let env_vars = pod["spec"]["containers"]
            .get(0)
            .and_then(|c| c["env"].as_array())
            .map(|v| v.as_slice())
            .unwrap_or(&[]);

        let has_official_chart_flag = env_vars.iter().any(|e| {
            e["name"].as_str() == Some("APOLLO_ROUTER_OFFICIAL_HELM_CHART")
                && e["value"].as_str() == Some("true")
        });
        if !has_official_chart_flag {
            return Err(anyhow!(
                "pod {name}: no APOLLO_ROUTER_OFFICIAL_HELM_CHART=true env var"
            ));
        }

        let has_graph_ref = env_vars.iter().any(|e| {
            e["name"].as_str() == Some("APOLLO_GRAPH_REF")
                && e["value"].as_str() == Some(expected_graph_ref)
        });
        if !has_graph_ref {
            return Err(anyhow!(
                "pod {name}: no APOLLO_GRAPH_REF={expected_graph_ref:?} env var"
            ));
        }
    }

    if !matched_any_pods {
        return Err(anyhow!("no pods matched label {label_key}={label_value}"));
    }

    Ok(())
}

/// Check the configMap collector and the router config it contains.
pub fn config_has_prometheus_fields(
    bundle_dir: &Path,
    namespace: &str,
    configmap_name: &str,
    configmap_key: &str,
    expected_listen: &str,
    expected_path: &str,
) -> CheckResult {
    let path = bundle_dir
        .join("configmaps")
        .join(namespace)
        .join(format!("{configmap_name}.json"));
    let doc = read_json(&path)?;
    let config_str = doc["data"][configmap_key].as_str().ok_or_else(|| {
        anyhow!(
            "{}: data[{configmap_key:?}] missing or not a string",
            path.display()
        )
    })?;
    let config: serde_yaml::Value = serde_yaml::from_str(config_str).with_context(|| {
        format!(
            "parsing YAML from {}'s data[{configmap_key:?}]",
            path.display()
        )
    })?;

    let prometheus = &config["telemetry"]["exporters"]["metrics"]["prometheus"];
    let enabled = prometheus["enabled"].as_bool();
    if enabled != Some(true) {
        return Err(anyhow!(
                "collected config: telemetry.exporters.metrics.prometheus.enabled = {enabled:?}, expected true"
            ));
    }
    let listen = prometheus["listen"].as_str().unwrap_or_default();
    if listen != expected_listen {
        return Err(anyhow!(
                "collected config: telemetry.exporters.metrics.prometheus.listen = {listen:?}, expected {expected_listen:?}"
            ));
    }
    let metrics_path = prometheus["path"].as_str().unwrap_or_default();
    if metrics_path != expected_path {
        return Err(anyhow!(
                "collected config: telemetry.exporters.metrics.prometheus.path = {metrics_path:?}, expected {expected_path:?}"
            ));
    }
    Ok(())
}

/// Check configMap collector and check the router config matches the expected.
pub fn config_matches_file_exactly(
    bundle_dir: &Path,
    namespace: &str,
    configmap_name: &str,
    configmap_key: &str,
    expected_file: &Path,
) -> CheckResult {
    let path = bundle_dir
        .join("configmaps")
        .join(namespace)
        .join(format!("{configmap_name}.json"));
    let doc = read_json(&path)?;
    let collected = doc["data"][configmap_key].as_str().ok_or_else(|| {
        anyhow!(
            "{}: data[{configmap_key:?}] missing or not a string",
            path.display()
        )
    })?;
    let expected = fs::read_to_string(expected_file)
        .with_context(|| format!("reading {}", expected_file.display()))?;
    if collected != expected {
        return Err(anyhow!(
                "collected config doesn't match {}\n--- expected ---\n{expected}\n--- collected ---\n{collected}",
                expected_file.display()
            ));
    }
    Ok(())
}

/// Check the <release>-supergraph schema ConfigMap.
/// See specs/collection/base_spec.md's Schema collection section.
/// This ConfigMap carries the router chart's standard label so the
/// clusterResources collector sweeps it up alongside every other
/// namespace ConfigMap (it's not collected by our own configMap collector,
///  which only targets the rendered router config.)
///
/// Trimmed on both sides before comparing: the chart's `|-` (strip) YAML chomping means the
/// collected content has no trailing newline, while the real source file does.
pub fn supergraph_schema_matches_file(
    bundle_dir: &Path,
    namespace: &str,
    configmap_name: &str,
    expected_file: &Path,
) -> CheckResult {
    let path = bundle_dir
        .join("cluster-resources/configmaps")
        .join(format!("{namespace}.json"));
    let doc = read_json(&path)?;

    let items = doc["items"].as_array().map(|v| v.as_slice()).unwrap_or(&[]);
    let configmap = items
        .iter()
        .find(|item| item["metadata"]["name"].as_str() == Some(configmap_name))
        .ok_or_else(|| {
            anyhow!(
                "no ConfigMap named {configmap_name:?} found in {}",
                path.display()
            )
        })?;

    let collected = configmap["data"]["supergraph-schema.graphql"]
        .as_str()
        .ok_or_else(|| {
            anyhow!(
                "ConfigMap {configmap_name:?}: data[\"supergraph-schema.graphql\"] missing or not a string"
            )
        })?;

    let expected = fs::read_to_string(expected_file)
        .with_context(|| format!("reading {}", expected_file.display()))?;

    if collected.trim_end() != expected.trim_end() {
        return Err(anyhow!(
            "collected supergraph schema doesn't match {}\n--- expected ---\n{}\n--- collected ---\n{}",
            expected_file.display(),
            expected,
            collected
        ));
    }

    Ok(())
}
