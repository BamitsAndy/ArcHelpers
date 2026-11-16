# PLAN — ArcGIS Pro help skill v2 (`pro-help-v2`)

Status: implemented 2026-11-16 (see §11 for measured results).
Scope: add a new, leaner skill; do **not** modify `.opencode/skills/pro-help-light-skill/`.

## 1. Goal

Create `.opencode/skills/pro-help-v2/` as a fresh skill that:

- keeps v1's resolver behaviour and CLI (drop-in compatible),
- cuts the instruction file to only what changes agent behaviour,
- makes the script substantially faster,
- caches the vendor sitemap **in the project folder** on first run.

The original skill remains byte-identical. v2 is validated side-by-side with v1 before it is used.

## 2. What was measured (this machine, 2026-11-16)

| Scenario | v1 (current) | Notes |
|---|---|---|
| Warm keyword search (`xy coordinate data`) | **5.7 s** | 6.0 s on the very first run incl. 0.48 s download |
| Warm `-Check` MISS | **6.9 s** | near-miss path is the slowest |
| Sitemap download (Invoke-WebRequest) | 0.48 s | 3.18 MB, ETag + Last-Modified present |
| `pwsh` startup (`-NoProfile`) | 0.31 s | fixed overhead |
| Regex over the 3.3 MB sitemap | ~0.24 s | single native pass, prototype |
| Building v1's 16,424 `PSCustomObject` entries | ~4.0 s | **main bottleneck** |

Other findings:

- 16,424 unique URLs; all under `/en/arcgis-pro/3.7/`; one `sdk/sitemap.xml` entry and one mixed-case page (`Create-natural-boundaries.html`), so matching and `-Check` must stay case-insensitive.
- `<loc>` entries are nearly all one-per-line, but line-anchored regex would drop the `sdk` entry. Search must not depend on line layout.
- v1's near-miss ranking produces poor suggestions (e.g. `help/mapping/layer-properties/x-y-data.html` → `help/data/imagery/faq.html`). Folder-scoped bigram similarity ranks the real target (`add-x-y-coordinate-data-as-a-layer`) first in 2 ms.

## 3. Decisions (confirmed)

- Name/dir: **`pro-help-v2`** (`name: pro-help-v2`, folder `.opencode/skills/pro-help-v2/`).
- Cache: **raw sitemap only** — `.cache/pro-help/sitemap.xml`, (~3.3 MB), created on first run.
- Compatibility: **drop-in** — same modes, parameters, stdout shapes, and exit codes. Additive `-CacheDir` only.

## 4. Target file tree

```
D:\python\projects\work\pro_help\
├─ .opencode\skills\pro-help-light-skill\      # untouched
├─ .opencode\skills\pro-help-v2\
│  ├─ SKILL.md                                 # ~45 lines / ~2.2 KB
│  └─ scripts\
│     ├─ resolve.ps1                           # ~200 lines, #Requires -Version 7.0
│     └─ selftest.ps1                          # optional dev-only golden-query harness
├─ .cache\pro-help\sitemap.xml                 # runtime cache (never committed)
└─ PLAN.md                                     # copy of this plan when out of plan mode
```

Notes:
- `.cache/` is added to `.gitignore` only if this directory later becomes a git repo (currently it is not).
- `selftest.ps1` is not referenced from `SKILL.md`, so it costs the agent no context.

## 5. SKILL.md v2 — lean structure

Delete everything that does not change agent behaviour: the 6-rule list, the fallback PowerShell block, the worked example + 404 metrics, and the 9 "verified seeds" (all are recoverable with `-Check`). Fold the explanation of why the sitemap is required into one sentence.

Target content (draft):

```markdown
---
name: pro-help-v2
description: Find and cite ArcGIS Pro / ArcPy help pages. Use for questions about
  ArcGIS Pro tools, geoprocessing, arcpy, or app workflows.
---

# ArcGIS Pro help

The docs table of contents is client-side, so index pages cannot be crawled. The vendor
sitemap lists every page; resolve against it instead of guessing slugs.

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

Always run with `pwsh -NoProfile`:

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
```

Open wording decision: if both skills remain installed, add one clause to the description
steering selection, e.g. “Uses a project-local sitemap cache; prefer for current work.”
Otherwise the two descriptions are near-identical and the agent may pick either.

## 6. `resolve.ps1` v2 design

### Contract (unchanged unless noted)

| Param | Set | Default | Behaviour |
|---|---|---|---|
| `Keywords` (positional) | Search | — | AND-ed tokens; separators `space , +` |
| `-Any` | Search | off | OR instead of AND |
| `-Area` | Search | `any` | `any\|help\|tool-reference\|arcpy` |
| `-Check` | Check | — | exact path/URL; `.htm` accepted |
| `-Folder` | Folder | — | prefix listing |
| `-Limit` | Search/Folder/**Check** | 15 | max results/suggestions |
| `-MaxAgeDays` | all | 7 | cache TTL |
| `-Refresh` | all | off | force re-download |
| `-Versioned` | all | off | pinned version output (**also applied to `-Check` now**) |
| `-CacheDir` | all | auto | **additive** override for the cache directory |

Exit codes: `0` success/FOUND, `1` no match/MISS, `2` usage or cache/download failure.

### Cache lifecycle (project-local)

1. Resolve cache dir: walk up from `$PSScriptRoot` until the `.opencode` directory is found,
   use its parent (project root) + `.cache\pro-help`; `-CacheDir` overrides; fall back to
   `$env:TEMP\pro-help` with a warning if the project path is not writable.
2. If `sitemap.xml` is missing, older than `-MaxAgeDays`, or `-Refresh`:
   - `Invoke-WebRequest` to `sitemap.xml.download` (progress disabled),
   - sanity-check: 10,000–100,000 `<loc>` values and at least one `/en/arcgis-pro/` page,
   - atomically `Move-Item -Force` over `sitemap.xml`.
3. On download/validation failure: if any cache exists, warn on stderr and use it; otherwise
   exit 2 with an actionable message (URL, cache path, `-Refresh` hint).
4. Read the file once with `[IO.File]::ReadAllText` (UTF-8). No XML DOM, no per-URL objects.

### Search pipeline (no full-corpus object graph)

1. Tokenise and normalise each keyword: lowercase, strip `- _ / .` so `x-y` and `xy`
   compare equal.
2. Build a separator-tolerant regex per token (`x[-_/. ]?y`) and combine:
   - AND: `(?i)<loc>https?://[^/]+/en/arcgis-pro/[^/]+/(?=[^<]*t1)(?=[^<]*t2)[^<]+</loc>`
   - `-Any`: one lookahead with `t1|t2`.
   - `-Area`: path becomes `…/[^/]+/help/`.
3. One `[regex]::Matches` call over the raw XML; URLs cannot match across `<`.
4. Parse only the candidates into lightweight objects (`Url`, `Relative`, `Leaf`).
5. Rank: token score desc → filename-word hits desc → relative-length asc → alphabetical
   (new final tiebreak for deterministic output).
6. Print `latest` URLs by default, pinned URLs with `-Versioned`. URLs are the only stdout.

Estimated warm cost: 0.24 s regex + 0.31 s startup ≈ **0.55 s** (target ≤ 0.8 s).

### `-Check`

- Normalise the needle (strip scheme/host/version/leading `/`, `.htm` → `.html`).
- Exact hit = one case-insensitive, escaped regex over the cache; no HashSet build needed.
- On MISS, near misses:
  1. candidates = pages under the needle's folder; score leaf slugs with bigram Dice
     coefficient, top `-Limit` (default 5);
  2. if the folder yields fewer than 2 candidates, fall back to a global OR-token scan and
     the same Dice ranking.
- Output `MISS\t<needle>`, blank line, `Near misses:`, two-space-indented relative paths.
- This replaces v1's document-frequency weighting, which surfaced unrelated pages.

### `-Folder`

One prefix regex, sort by relative-path length, print up to `-Limit` URLs (respect
`-Versioned`). Same as v1 but without building the corpus.

### Implementation hygiene

- `#Requires -Version 7.0`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`.
- No `Where-Object`/`ForEach-Object` over the full corpus.
- stdout = results only; `Write-Verbose`/`Write-Warning` for everything else.
- Keep the script header to a short synopsis, the cache note, and 3 examples.
- Decode XML entities in URLs (`&amp;`) even though none exist today.

### Explicitly out of scope

- Conditional GET/ETag refresh (would need a sidecar file; v2 is raw-sitemap-only).
- JSON output, new modes, extra areas (`sdk`), cache housekeeping commands.
- PowerShell 5.1 support.

## 7. Validation plan

Golden corpus (run against v1 and v2, diff sets and order):

| Command | Expected |
|---|---|
| `xy coordinate data` | 3 URLs incl. `add-x-y-coordinate-data-as-a-layer.html` |
| `circle -Area help` | 2 URLs (`create-circles-and-ellipses`, `create-circles`) |
| `buffer -Area tool-reference` | `tool-reference/analysis/buffer.html` first |
| `create polygon features` | `help/editing/create-polygon-features.html` first |
| `graphic layer` / `graphics -Any` | graphics-layer pages |
| `-Check help/.../add-x-y-coordinate-data-as-a-layer.html` | `FOUND`, exit 0 |
| `-Check help/mapping/layer-properties/x-y-data.html` | `MISS`, exit 1, target ranked first near-miss |
| `-Folder help/editing -Limit 10` | 10 shortest paths, exit 0 |
| `-Versioned buffer` | URL contains `/3.7/` |
| `zzzzqqq` | `No page matched`, exit 1 |
| no args | usage, exit 2 |

Operational tests:
1. Cold cache: delete `.cache/pro-help`, time first run (target ≤ 2 s) and verify only
   `sitemap.xml` was created (3.2–3.4 MB).
2. Warm run: ≤ 0.8 s for search, ≤ 1.0 s for `-Check` MISS.
3. `-Refresh`: re-downloads; mtime updates.
4. Corrupt cache: truncate to 1 KB → script re-downloads or exits 2 with a clear message,
   never returns garbage.
5. Offline with cache: warns on stderr and still returns results.
6. Offline without cache: exit 2, actionable message.
7. HEAD-check 20 returned URLs across modes; expect 200 and URLs present in the sitemap.
8. Verify v1 hashes (SHA-256 of `SKILL.md` and `scripts/resolve.ps1`) are unchanged after
   implementation.
9. Frontmatter parse + skill discovery in a fresh OpenCode session.

Acceptance criteria: all corpus rows match v1 (except documented improvements), operational
tests pass, `SKILL.md` ≤ 45 lines and ≤ 2.5 KB, and no v1 file differs.

## 8. Implementation steps

1. Record SHA-256 of the two v1 files as the no-change baseline.
2. Create `.opencode/skills/pro-help-v2/scripts/` and write `SKILL.md` from the draft.
3. Implement `resolve.ps1` in this order: cache/download → `-Check` → keyword search →
   `-Folder` → near-miss ranking.
4. Run the golden corpus and tune ranking until it matches v1's sets.
5. Measure cold/warm/`-Check` timings; record results in the PR/commit notes.
6. Optional: add `scripts/selftest.ps1` capturing the corpus (not referenced by SKILL.md).
7. Final checks: v1 hashes, line/size budget, no stdout noise, exit codes.

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Regex matching drifts from v1 semantics | Golden corpus diff; separator-normalised token test cases |
| Vendor changes sitemap structure | Sanity-count check, stale-cache fallback, clear error, raw XML retained |
| Project cache unwritable (OneDrive/read-only) | Temp fallback + warning; `-CacheDir` override |
| Two near-identical skills confuse selection | Distinct description hint + `v2` name; revisit retiring v1 later (user decision) |
| 3.3 MB per project | Documented cache path; `.gitignore`; TTL avoids re-downloads |
| Near-miss quality regressions | Folder-scoped first, global fallback; assert the `x-y-data` case in tests |

## 10. Definition of done

- `pro-help-v2` resolves the golden corpus with v1-compatible output and exit codes.
- Warm search is roughly 10× faster than v1 (≤ 0.8 s vs 5.7 s).
- First run creates `.cache/pro-help/sitemap.xml` and needs no manual setup.
- `SKILL.md` contains only rules an agent must follow, with no duplicated fallback.
- `.opencode/skills/pro-help-light-skill/` is unchanged, proven by hash.

## 11. Implementation record (2026-11-16)

Delivered:

```
.opencode\skills\pro-help-v2\
├─ SKILL.md                 45 lines, 2,275 bytes
└─ scripts\
   ├─ resolve.ps1           cache/download → -Check → keyword search → -Folder → Dice near misses
   └─ selftest.ps1          14 golden cases; dev-only, not referenced by SKILL.md
.cache\pro-help\sitemap.xml  3,337,318 bytes, created on first run
```

Measured on this machine (child `pwsh -NoProfile`, 3 runs each):

| Scenario | v1 | v2 |
|---|---|---|
| Cold cache, first search | 6.0 s | **1.4–1.6 s** (download + validate) |
| Warm keyword search | 5.7 s | **0.77–0.79 s** |
| Warm `-Check` FOUND | ~6 s (corpus build) | **0.50–0.51 s** |
| Warm `-Check` MISS | 6.9 s | **0.83–0.85 s** |
| `pwsh` startup alone | 0.31 s | 0.31 s |

Where the warm time goes: ~0.29 s startup, ~0.15 s cache resolve + read + `<loc>` count,
~0.26 s single regex sweep, remainder ranking/output.

Validation results:

- Golden corpus: `selftest.ps1` → 14/14 pass, exit 0. `-Check x-y-data.html` ranks
  `add-x-y-coordinate-data-as-a-layer.html` first.
- Cold run creates only `sitemap.xml` (3.2–3.4 MB) in `.cache\pro-help`.
- `-Refresh` re-downloads and updates mtime.
- Truncated cache (1 KB) is treated as stale and re-downloaded; if the download also fails
  the script exits 2 instead of returning garbage.
- Download failure with a usable cache: `WARNING:` on **stderr**, results still on stdout,
  exit 0. Download failure with no cache: exit 2, message names the URL, cache path and
  `-Refresh`.
- 20 URLs sampled across modes: all HTTP 200 and all present in the sitemap.
- stdout purity: only URLs, `FOUND`/`MISS` rows, `Near misses:` rows, `No page matched`,
  `usage:`.
- v1 unchanged — SHA-256 `966C05A4…BEDBA8` (`SKILL.md`) and `66049B4B…AB0900`
  (`scripts/resolve.ps1`) match the pre-work baseline.
- `pro-help-v2` is discovered by OpenCode and its frontmatter parses.

Deliberate refinements vs the design notes:

- `-Check` exact hit uses an ordinal-ignore-case `IndexOf` plus boundary confirmation
  instead of a regex sweep (0.02 s vs 0.20 s); behaviour is identical.
- `<loc>` counting uses one `String.Replace` (9 ms vs ~200 ms for a regex count).
- `usage:` stays on stdout (v1 used `Write-Host`); warnings and fatal errors go to stderr.
- `-Check` respects `-Versioned` (latest by default, pinned with the switch) and defaults to
  5 near-miss suggestions unless `-Limit` is passed.
