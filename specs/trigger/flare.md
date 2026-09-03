# Trigger — flare (on-demand)

This is the trigger-layer spec for flare (on-demand) trigger. This is distinct from what gets collected (`specs/collection/`) or where it executes (`specs/deployment/`). Per `specs/architecture.md`'s layer model, trigger varies independently of the other two.

## What triggers collection

**Exactly one thing: a human decides to run it.** There is no schedule, no threshold, no watched metric, and no event of any kind that starts a collection on its own. Every invocation documented in `specs/user_experience.md` → On-demand (flare-style) collection reduces to the same underlying act: **a human deciding, at a moment of their own choosing, that collection should happen now** — whether by running `kubectl support-bundle --load-cluster-specs` directly, or by installing a chart that runs it on their behalf immediately upon install (`mode: job` — see `specs/deployment/v1/v1.md` for how that delegation works). What's constant across every tier is that a human, not a clock or a watched condition determines the timing.

## What on-demand entails

- **No schedule.** No CronJob, no periodic collection, no "every N hours" cadence. A collection happens exactly as many times as a human runs the command.

- **No threshold.** No component in v1 watches memory, CPU, restart counts, or any other signal and decides on its own that a collection is warranted. There is no watcher process to watch anything with.

## What this doc does not cover

Everything about *how* a triggered collection actually runs — the chart, the two modes, RBAC, execution location, retrieval — belongs to `specs/deployment/v1/v1.md` and is not restated here. Everything about *what* gets collected once triggered belongs to `specs/collection/`. This file's entire scope is the moment before either of those starts: what causes that moment to occur.
