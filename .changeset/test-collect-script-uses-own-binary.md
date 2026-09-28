---
category: test
breaking: false
---

Test that collect.sh uses its own cached binary, never a customer's PATH

Adds mise-tasks/test-collect-script, wired into CI: puts a fake "old" support-bundle
earlier on PATH, plus a stubbed kubectl, and confirms collect.sh only ever runs its
own cached, version-pinned binary.
