mod checks;
mod cli;

use clap::Parser;
use cli::{load_expected_values, Args, Mode, Tier};
use std::process::ExitCode;

fn main() -> anyhow::Result<ExitCode> {
    let args = Args::parse();
    let mode_str = match args.mode {
        Mode::Local => "local",
        Mode::Job => "job",
    };
    let label_key = "app.kubernetes.io/name";
    let label_value = "router";
    let (configmap_name, configmap_key) = args.tier.configmap();
    let expected = load_expected_values(args.expected_values.as_ref())?;

    let mut results: Vec<(&str, checks::CheckResult)> = vec![
        (
            "meta.json is accurate",
            checks::meta_json_is_accurate(&args.bundle_dir, &args.namespace, mode_str),
        ),
        (
            "router-metrics scraped real Prometheus output",
            checks::router_metrics_has_real_scrape(&args.bundle_dir),
        ),
        (
            "clusterResources: pods are healthy",
            checks::pods_are_healthy(
                &args.bundle_dir,
                &args.namespace,
                label_key,
                label_value,
                expected.image.as_deref(),
                &expected.resources,
            ),
        ),
        (
            "clusterResources: nodes are healthy",
            checks::nodes_are_healthy(&args.bundle_dir),
        ),
        (
            "nodeMetrics collected real kubelet data",
            checks::node_metrics_has_real_kubelet_data(&args.bundle_dir),
        ),
        (
            "router-logs collected the router's startup log",
            checks::router_logs_contains_expected_content(&args.bundle_dir, &expected.log_target),
        ),
        (
            "APOLLO_KEY never appears in the bundle",
            checks::apollo_key_never_appears(&args.bundle_dir),
        ),
    ];

    // The two tiers' ConfigMap checks use different mechanisms because the ConfigMaps
    // themselves aren't produced the same way:
    //   - raw-manifest's ConfigMap is hand-authored by us so an exact diff is possible.
    //   - the official chart's templates/configmap.yaml does mustMergeOverwrite, injecting
    //     telemetry.exporters.metrics.common.resource.service.name on top of whatever we
    //     pass in values.yaml. Therefore, we only check the specific values we configured.
    match args.tier {
        Tier::RawManifest => {
            let config_file = expected.config_file.ok_or_else(|| {
                anyhow::anyhow!("--expected-values must set config_file for --tier raw-manifest")
            })?;
            results.push((
                "configMap matches the real router config exactly",
                checks::config_matches_file_exactly(
                    &args.bundle_dir,
                    &args.namespace,
                    configmap_name,
                    configmap_key,
                    &config_file,
                ),
            ));
        }
        Tier::OfficialChart => {
            let graph_ref = expected.graph_ref.ok_or_else(|| {
                anyhow::anyhow!("--expected-values must set graph_ref for --tier official-chart")
            })?;
            results.push((
                "APOLLO_GRAPH_REF and APOLLO_ROUTER_OFFICIAL_HELM_CHART env vars present",
                checks::official_chart_env_vars_present(
                    &args.bundle_dir,
                    &args.namespace,
                    label_key,
                    label_value,
                    &graph_ref,
                ),
            ));

            results.push((
                "configMap has the expected prometheus fields",
                checks::config_has_prometheus_fields(
                    &args.bundle_dir,
                    &args.namespace,
                    configmap_name,
                    configmap_key,
                    &expected.metrics_listen,
                    &expected.metrics_path,
                ),
            ));

            let supergraph_schema_file = expected.supergraph_schema_file.ok_or_else(|| {
                anyhow::anyhow!(
                    "--expected-values must set supergraph_schema_file for --tier official-chart"
                )
            })?;
            results.push((
                "<release>-supergraph ConfigMap matches the real schema",
                checks::supergraph_schema_matches_file(
                    &args.bundle_dir,
                    &args.namespace,
                    // router.fullname + "-supergraph" (templates/supergraph-cm.yaml) -
                    // hardcoded the same way configmap_name assumes release name "router".
                    "router-supergraph",
                    &supergraph_schema_file,
                ),
            ));
        }
    }

    let mut any_failed = false;
    for (name, result) in &results {
        match result {
            Ok(()) => println!("PASS  {name}"),
            Err(reason) => {
                any_failed = true;
                println!("FAIL  {name}");
                // {:?} (not {}) so the full anyhow context chain prints, e.g. every
                // .with_context(...) layer, not just the innermost message.
                for line in format!("{reason:?}").lines() {
                    println!("      {line}");
                }
            }
        }
    }

    Ok(if any_failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    })
}
