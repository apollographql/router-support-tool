---
category: docs
breaking: false
---

Move the Getting Started overview page out of its own nested directory

`docs/getting-started/getting-started.mdx` rendered at
`/docs/router-support-tool/getting-started/getting-started` - a redundant doubled path
segment, and the shorter `/getting-started` 404'd rather than resolving to it. Moved the
file to `docs/getting-started.mdx` so it renders at `/docs/router-support-tool/getting-started`
directly. `local-mode.mdx`/`job-mode.mdx` stay under `getting-started/`, since their
own paths aren't redundant with their filenames.
