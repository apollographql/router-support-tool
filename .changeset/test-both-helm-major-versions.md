---
category: ci
breaking: false
---

Test against both Helm major versions

`helm_lint`, `spec_lint`, and the `official-chart` Chainsaw test now run
under both major Helm versions.

A a custom Renovate manager has been added so both of those explicit 
versions get kept current automatically.
