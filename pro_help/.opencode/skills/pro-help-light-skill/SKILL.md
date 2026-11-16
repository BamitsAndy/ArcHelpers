---
name: pro-help-light-skill
description: search arcgis pro and arcpy help to answer user questions about this application
---

# ArcGIS Pro help — search protocol

Answer from the vendor docs and cite the URL you actually opened. Never cite a path you
have not successfully fetched.

## Rules (all mandatory)

1. **Resolve, don't guess.** Run `scripts/resolve.ps1` before fetching any `help/...`
   page. It greps the vendor sitemap (~16.4k URLs) that the docs site publishes, so you
   get the real path in one short command instead of a 404.
2. **One 404 is the limit.** If a fetch 404s, do not retry `.htm`, singular/plural, or
   neighbouring folders. Run the resolver for that concept and continue from its output.
3. **`help/...` paths may never come from memory.** They are recall-hostile: the slug is
   easy to half-remember and the folder is easy to get wrong (e.g.
   `add-x-y-coordinate-data-as-a-layer` lives under `help/mapping/layer-properties/`,
   not `help/data/tables/`). Only the resolver may produce these paths.
4. **`tool-reference/...` and `arcpy/...` paths are safe to construct from memory**
   (`tool-reference/<toolbox>/<tool>.html`, `arcpy/<module>/<page>.html`), but run
   `-Check` when the answer cites them.
5. **Tools:** `webfetch` and `shell` only. There is no web-search tool; do not attempt one.
6. **Citations:** every help-derived fact carries the URL you successfully fetched.
   Anything from prior knowledge is tagged `(model knowledge — not verified against help)`.

## Resolver

```
pwsh .opencode/skills/pro-help-light-skill/scripts/resolve.ps1 xy coordinate data
pwsh .opencode/skills/pro-help-light-skill/scripts/resolve.ps1 circle -Area help
pwsh .opencode/skills/pro-help-light-skill/scripts/resolve.ps1 -Check help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html
pwsh .opencode/skills/pro-help-light-skill/scripts/resolve.ps1 -Folder help/editing -Limit 40
```

- **Keyword mode:** every keyword must appear in the URL; matches in the page filename
  rank first. Prints `latest` URLs, ready to `webfetch`.
- **Query style:** one or two distinctive nouns beats a phrase. `circle -Area help`
  resolves; `circle graphic` does not (no single page carries both). Add `-Any` to widen
  to OR, or `-Folder` to browse a section.
- **`-Check <path|url>`:** prints `FOUND` (exit 0) or `MISS` plus near misses (exit 1).
  Use it before citing a remembered URL.
- **`-Area help|tool-reference|arcpy`** narrows the search.
- **Cache:** `%TEMP%\pro_sitemap.xml`, reused for 7 days. `-Refresh` forces a re-download.
  `-Versioned` prints the pinned version (currently `3.7`) instead of the `latest` alias.

Fallback if the script cannot run (never `webfetch` the sitemap — it is ~3.2 MB):

```powershell
$f = "$env:TEMP\pro_sitemap.xml"
if (!(Test-Path $f)) { Invoke-WebRequest 'https://doc.esri.com/en/arcgis-pro/latest/sitemap.xml' -OutFile $f }
Select-String -Path $f -Pattern 'graphic'
```

### Worked example

Question: "draw a circle around a point from a lat/lon spreadsheet."

```
resolve.ps1 circle -Area help
  -> help/editing/create-circles-and-ellipses.html      (draw it as a feature)
  -> help/data/distance-direction/create-circles.html   (create circles from a table)
resolve.ps1 xy coordinate data
  -> tool-reference/data-management/add-xy-coordinates.html
  -> help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html
```

Four resolutions, four fetches, zero 404s — versus 19 calls and 10 failures when the
slugs were recalled instead.

## Entry points — orientation only

- UI/UX and app functionality — https://doc.esri.com/en/arcgis-pro/latest/help/main/welcome-to-the-arcgis-pro-app-help.html
- Geoprocessing tools — https://doc.esri.com/en/arcgis-pro/latest/tool-reference/main/arcgis-pro-tool-reference.html
- ArcPy — https://doc.esri.com/en/arcgis-pro/latest/arcpy/main/arcgis-pro-arcpy-reference.html

These are prose intros, **not navigable indexes**: the site's table of contents is
rendered client-side, so the served HTML carries ~30–50 `href`s of which only 1–4 point
at documentation pages (the geoprocessing index exposes zero tool links). You cannot
crawl from them to a target page. Use them to frame a topic, then resolve the page.

## Verified seeds (checked 2026-11-16, ArcGIS Pro 3.7)

- `tool-reference/analysis/buffer.html`
- `tool-reference/data-management/xy-table-to-point.html`
- `help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html`
- `help/editing/create-circles-and-ellipses.html`
- `help/data/distance-direction/create-circles.html`
- `help/editing/create-polygon-features.html`
- `help/editing/segment-construction-tools.html`
- `help/mapping/layer-properties/graphics-layers.html`
- `help/mapping/layer-properties/work-with-graphic-elements-in-a-map.html`

Prefix with `https://doc.esri.com/en/arcgis-pro/latest/`. Re-verify with `-Check` before
quoting when the answer is high-stakes.
