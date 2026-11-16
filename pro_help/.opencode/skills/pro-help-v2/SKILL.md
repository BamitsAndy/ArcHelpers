---
name: pro-help-v2
description: Find and cite ArcGIS Pro / ArcPy help pages. Use for questions about
  ArcGIS Pro tools, geoprocessing, arcpy, or app workflows. Prefer this skill over
  pro-help-light-skill for current work; it caches the vendor sitemap in the project.
---

# ArcGIS Pro help

The docs table of contents is client-side, so resolve paths against the vendor sitemap
instead of guessing slugs.

## Rules

1. Resolve every `help/...` path with `scripts/resolve.ps1` before fetching. Never write
   one from memory.
2. One 404 is the limit. On a 404, run the resolver for that concept; do not retry `.htm`,
   plural, or neighbouring folders.
3. `tool-reference/<toolbox>/<tool>.html` and `arcpy/<module>/<page>.html` may be recalled,
   but verify with `-Check` before citing.
4. Cite the URL you fetched for every help-derived fact. Tag anything else
   `(model knowledge — not verified against help)`.
5. Tools: `webfetch` and `shell` only. Cite vendor docs only, never blogs or forums.

## Resolver

```
pwsh -NoProfile -File .opencode/skills/pro-help-v2/scripts/resolve.ps1 xy coordinate data
pwsh -NoProfile -File .opencode/skills/pro-help-v2/scripts/resolve.ps1 circle -Area help
pwsh -NoProfile -File .opencode/skills/pro-help-v2/scripts/resolve.ps1 -Check help/mapping/layer-properties/x-y-data.html
pwsh -NoProfile -File .opencode/skills/pro-help-v2/scripts/resolve.ps1 -Folder help/editing -Limit 20
```

- Keywords are AND-ed and filename matches rank first. One or two distinctive nouns beat a
  phrase. `-Any` = OR; `-Area help|tool-reference|arcpy` narrows; `-Limit` caps output.
- `-Check <path|url>` prints `FOUND` (exit 0) or `MISS` + near misses (exit 1).
- `-Versioned` prints the pinned version (3.7) instead of the `latest` alias.
- Sitemap cache: `.cache/pro-help/sitemap.xml`, reused 7 days; `-Refresh` re-downloads.
  Created on first run — never `webfetch` the sitemap (~3.3 MB).

## Entry points (orientation only, not indexes)

- App help: https://doc.esri.com/en/arcgis-pro/latest/help/main/welcome-to-the-arcgis-pro-app-help.html
- Tools: https://doc.esri.com/en/arcgis-pro/latest/tool-reference/main/arcgis-pro-tool-reference.html
- ArcPy: https://doc.esri.com/en/arcgis-pro/latest/arcpy/main/arcgis-pro-arcpy-reference.html
