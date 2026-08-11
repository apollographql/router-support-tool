# Deployment — v1, Apollo Operator

TODO: place operator specific deployment concerns and design for v1 here.

`specs/deployment/v1/v1.md` covers the `router-diagnostics` chart and the tiers that install it. This file owns everything specific to how the Apollo Operator provisions, configures, and gates the support-bundle spec.

What is known so far: the Operator writes the same base spec into a cluster ConfigMap with its targeting values already populated from conventions it knows, and the customer runs `kubectl support-bundle --load-cluster-specs`. There is one spec across all tiers — the Operator differs only in who fills in the values, not in which spec runs.

## TODO

- [ ] **Confirm the Operator's metrics port and bind address, then state the outcome as a fact.** The base spec's `http` collector targets a fixed `:9090/metrics`, taken from rendering the official Apollo router Helm chart (v2.10.5). Whether the Operator matches that is a convention Apollo defines, so it is knowable by inspection rather than an environmental unknown to be hedged — and it must not be left as "returns empty if the port differs." Two acceptable resolutions:
  - If the Operator uses `:9090`, the tier behaves like the official chart tier, subject to the same exporter-enabled and reachable-bind conditions.
  - If it differs, either the Operator populates the port when it writes the spec (consistent with how it already populates every other targeting value), or the base spec carries the Operator's port as a second known default.

  Not acceptable: leaving the tier silently empty. The zero-config tier is the one where an unexplained missing section is least diagnosable. Until this is answered, metrics on this tier are **unspecified** — see `specs/collection/base_spec.md` → Prometheus metrics.

- [ ] **Decide whether provisioning the spec ConfigMap is opt-in.** A diagnostic ConfigMap appearing in a production namespace without the customer asking for it is the kind of surprise that draws change-control friction, so the default matters. `specs/user_experience.md` currently tells customers to check their Operator configuration for whether provisioning is enabled, which needs to match whatever is decided here.

- [ ] **Specify how Operator customers set preferences that other tiers set as chart values.** This is a functional gap, not a formality: `redaction.includeSchema` and the `logs.maxAge` / `logs.maxLines` bounds are chart values, and Operator customers do not install the chart. As things stand the zero-config tier has no way to opt out of including schema/SDL — likely to matter most to exactly the customers who chose the Operator.

- [ ] **Document which targeting values the Operator populates, and from what**, so the one-spec guarantee in `v1.md` is verifiable rather than asserted.

- [ ] **Decide whether the Operator pins or tracks a collection engine version.** Operator customers still install the `support-bundle` plugin locally, so they carry the same unpinned-engine exposure as `mode: local`. See `specs/deployment/v1/v1.md` → Collection engine version.
