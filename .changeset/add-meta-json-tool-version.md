---
category: feat
breaking: false
---

Record the tool's own version in `meta.json`

`meta.json` had no way to tell which release of router-support-tool produced a given
bundle. Adds `version`, rendered from the chart's own `Chart.yaml` version at
install time - the same `vX.Y.Z` published across the image, chart, and collect script.
