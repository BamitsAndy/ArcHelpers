---
name: pro-help-v2
description: Resolve and cite ArcGIS Pro / ArcPy documentation URLs from Esri's sitemap.
  Use for questions about ArcGIS Pro tools, geoprocessing, arcpy, or app workflows.
  Resolves every path against the cached vendor sitemap instead of guessing slugs.
allowed-tools: Bash, WebFetch
---

# ArcGIS Pro help

The docs table of contents is client-side, so resolve paths against the vendor sitemap
instead of guessing slugs.

## Worked example

```
pwsh -NoProfile -File .claude/skills/pro-help-v2/scripts/resolve.ps1 xy coordinate data
```

stdout is one URL per line, best match first:

```
https://doc.esri.com/en/arcgis-pro/latest/tool-reference/data-management/add-xy-coordinates.html
https://doc.esri.com/en/arcgis-pro/latest/help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html
```

`WebFetch` the first URL, answer from it, and cite it.

## Rules

1. Never fetch a URL you have not seen in resolver output. A remembered path is fine as a
   `-Check` input, never as a fetch target.
2. One 404 is the limit. On a 404, run the resolver for that concept; do not retry `.htm`,
   plural, or neighbouring folders.
3. Cite the URL you fetched for every help-derived fact. Tag anything else
   `(model knowledge — not verified against help)`.
4. Use `Bash` and `WebFetch` only. Do not use `WebSearch`. Cite `doc.esri.com` only —
   never blogs, forums, or Esri Community.

## Choosing among results

- Results are ranked. Fetch the first; if it is wrong, fetch the second before re-resolving.
- `arcpy/...` for Python syntax, `tool-reference/...` for tool parameters and the tool
  dialog, `help/...` for app workflows. Narrow with `-Area` when you know which you need.

## Resolver

```
pwsh -NoProfile -File .claude/skills/pro-help-v2/scripts/resolve.ps1 xy coordinate data
pwsh -NoProfile -File .claude/skills/pro-help-v2/scripts/resolve.ps1 circle -Area help
pwsh -NoProfile -File .claude/skills/pro-help-v2/scripts/resolve.ps1 -Check help/mapping/layer-properties/x-y-data.html
pwsh -NoProfile -File .claude/skills/pro-help-v2/scripts/resolve.ps1 -Folder help/editing -Limit 20
```

- Output contract: stdout is fetchable URLs and nothing else. Diagnostics (`MISS`, near
  misses, no-match, usage) go to stderr. Exit `0` = at least one URL, `1` = nothing
  matched, `2` = usage error or hard failure.
- Keywords are AND-ed and filename matches rank first. One or two distinctive nouns beat a
  phrase. `-Any` = OR; `-Area help|tool-reference|arcpy` narrows; `-Limit` caps output
  (default 8).
- `-Check <path|url>` prints the canonical URL (exit 0), or `MISS` plus near misses on
  stderr (exit 1). Accepts `.htm` and any version segment.
- `-Versioned` prints the concrete version from the sitemap instead of the `latest` alias.
- Sitemap cache: `.cache/pro-help/sitemap.xml` plus the derived `paths.txt`, reused 7 days.
  Created on first run — never `WebFetch` the sitemap (~3.3 MB). If results look stale or
  wrong, re-run once with `-Refresh`.
- Run it as a child process exactly as shown: the Bash tool is Git Bash on Windows, not
  PowerShell. Needs PowerShell 5.1 or newer (`pwsh`, or `powershell` on Windows).

## Entry points (orientation only, not indexes)

- App help: https://doc.esri.com/en/arcgis-pro/latest/help/main/welcome-to-the-arcgis-pro-app-help.html
- Tools: https://doc.esri.com/en/arcgis-pro/latest/tool-reference/main/arcgis-pro-tool-reference.html
- ArcPy: https://doc.esri.com/en/arcgis-pro/latest/arcpy/main/arcgis-pro-arcpy-reference.html
