# Secret-shaped env vars in pod specs

## The problem

`clusterResources` collects the full pod spec,`spec.containers[].env` included, for every pod, deployment, and replicaset in the namespace (`specs/collection/base_spec.md` → "Pod spec (`spec.containers[].env`)" row). When a customer sets a secret as a literal value, the literal value is captured verbatim.

## Redactor: any `*_KEY`-named env var

```yaml
- name: router-key-named-env-var
  removals:
    regex:
      - selector: '"name":\s*"(?:[A-Z0-9_]*_)?KEY"'
        redactor: '("value":\s*")(?P<mask>[^"]*)(")'
```

This masks the value of **any** env var whose name ends in `KEY` or `_KEY`, not just `APOLLO_KEY`.

### Notes

- **Deliberately has no `fileSelector` so it runs against every file in the bundle.**
- **This masks some non-secret values too, this is an accepted tradeoff** A `PRIMARY_KEY`, for example, will get masked by this rule.

## Redactor: any `*_PASS`-named env var

```yaml
- name: router-pass-named-env-var
  removals:
    regex:
      - selector: '"name":\s*"(?:[A-Z0-9_]*_)?PASS"'
        redactor: '("value":\s*")(?P<mask>[^"]*)(")'
```

### Notes

- **Deliberately has no `fileSelector` so it runs against every file in the bundle.**
- troubleshoot's built-in redactors mask a `*password*`-named env var, but not the common `PASS` abbreviation.

## What's deliberately left visible

`APOLLO_GRAPH_REF` and `APOLLO_ROUTER_OFFICIAL_HELM_CHART`, the other env vars this repo's base spec table calls out — neither is a credential, both are useful for bundle tagging and deployment-tier detection (`specs/collection/base_spec.md`).
