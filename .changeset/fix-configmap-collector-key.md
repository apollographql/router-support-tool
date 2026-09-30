---
category: fix
breaking: false
---

Fix keyExists always false in configmap collector output

The configMap collector was missing `key: configuration.yaml` causing troubleshoot.sh
to always report `keyExists: false` in the collected output even when the router config
was successfully captured. Adding the key makes `keyExists` accurately reflect whether
the standard Apollo Router Helm chart config key is present. Raw-manifest and custom
deployments using a different key name will still see `keyExists: false` since that key
does not exist in their ConfigMap. Collection behavior is unchanged,`includeAllData: true` 
still captures all keys regardless.
