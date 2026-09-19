use crate::checks::ExpectedResources;
use clap::{Parser, ValueEnum};
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

/// Verifies a router-diagnostics support bundle against specs/collection/base_spec.md's
/// "What the base spec collects" tables.
/// This CLI is called by the GitHub Actions integration tests that cover the router-diagnostics plugin.
#[derive(Parser)]
#[command(version, about)]
pub struct Args {
    /// The extracted support-bundle-* directory (untarred, not the .tar.gz).
    #[arg(long)]
    pub bundle_dir: PathBuf,

    /// The namespace collection was scoped to.
    #[arg(long)]
    pub namespace: String,

    /// Which deployment tier the router was deployed with
    #[arg(long, value_enum)]
    pub tier: Tier,

    /// helm router-diagnostics mode the bundle was collected under.
    #[arg(long, value_enum, default_value = "local")]
    pub mode: Mode,

    /// Optional JSON file overriding the expected_* values checked against the bundle.
    /// Any field left out keeps its default.
    #[arg(long)]
    pub expected_values: Option<PathBuf>,
}

#[derive(Clone, ValueEnum)]
pub enum Tier {
    RawManifest,
    OfficialChart,
}

#[derive(Clone, ValueEnum)]
pub enum Mode {
    Local,
    Job,
}

impl Tier {
    pub fn configmap(&self) -> (&'static str, &'static str) {
        match self {
            // Matches the name used in raw-manifest-plugin-integration-test.yaml's own
            // `kubectl create configmap router-config --from-file=router.yaml=...` step.
            Tier::RawManifest => ("router-config", "router.yaml"),
            // Named by the official chart's router.fullname helper (templates/_helpers.tpl)
            // + templates/configmap.yaml.
            Tier::OfficialChart => ("router", "configuration.yaml"),
        }
    }
}

/// What to check the bundle's contents against. Every field is optional in the JSON file.
/// Anything left out keeps the default.
#[derive(Deserialize)]
#[serde(default)]
pub struct ExpectedValues {
    /// Expected router container image, e.g. ghcr.io/apollographql/router:v2.17.0.
    /// Required for --tier raw-manifest
    pub image: Option<String>,

    /// Expected APOLLO_GRAPH_REF value. Required for --tier official-chart
    pub graph_ref: Option<String>,

    /// Local file the collected router config must match byte-for-byte. Required for
    /// --tier raw-manifest (official-chart is checked by field instead,
    /// see checks::config_has_prometheus_fields).
    pub config_file: Option<PathBuf>,

    /// Expected telemetry.exporters.metrics.prometheus.listen in the rendered config.
    pub metrics_listen: String,

    /// Expected telemetry.exporters.metrics.prometheus.path in the rendered config.
    pub metrics_path: String,

    /// Expected router container resources.requests/limits.
    pub resources: ExpectedResources,

    /// Expected target field in router-logs' startup log line.
    pub log_target: String,
}

impl Default for ExpectedValues {
    fn default() -> Self {
        Self {
            image: None,
            graph_ref: None,
            config_file: None,
            metrics_listen: "0.0.0.0:9090".to_string(),
            metrics_path: "/metrics".to_string(),
            resources: ExpectedResources::default(),
            log_target: "apollo_router::axum_factory::axum_http_server_factory".to_string(),
        }
    }
}

pub fn load_expected_values(path: Option<&PathBuf>) -> anyhow::Result<ExpectedValues> {
    match path {
        None => Ok(ExpectedValues::default()),
        Some(path) => {
            let raw = fs::read_to_string(path)
                .map_err(|e| anyhow::anyhow!("reading {}: {e}", path.display()))?;
            serde_json::from_str(&raw)
                .map_err(|e| anyhow::anyhow!("parsing {} as JSON: {e}", path.display()))
        }
    }
}
