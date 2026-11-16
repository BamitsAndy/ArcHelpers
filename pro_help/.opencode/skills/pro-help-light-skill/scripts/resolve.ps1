<#
.SYNOPSIS
    Resolve ArcGIS Pro help page URLs from the vendor sitemap. Never guess a path.

.DESCRIPTION
    The doc.esri.com table of contents is rendered client-side, so help pages cannot be
    reached by crawling from the published index pages. The sitemap, however, lists every
    published page. This script caches that sitemap and greps it, so a page can be located
    in one command instead of by guessing slugs.

    Keyword mode  : all keywords must appear in the URL; shortest match first.
    -Check mode   : validate one exact path or URL, with near-miss suggestions on failure.

.PARAMETER Keywords
    Words that describe the page, e.g. 'xy coordinate data'. Case-insensitive; any of
    space, comma, or '+' separates words. Every word must be present in the URL.

.PARAMETER Check
    A page path or full URL to validate, e.g.
    help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html
    Accepts a trailing '.htm' for convenience.

.PARAMETER Area
    Restrict keyword search to one documentation area.

.PARAMETER Limit
    Maximum number of URLs to return (default 15).

.PARAMETER MaxAgeDays
    Reuse the cached sitemap while it is younger than this (default 7 days).

.PARAMETER Refresh
    Force a fresh sitemap download.

.PARAMETER Versioned
    Emit the pinned version (e.g. 3.7) instead of the 'latest' alias.

.EXAMPLE
    ./resolve.ps1 xy coordinate data

.EXAMPLE
    ./resolve.ps1 -Check help/mapping/layer-properties/x-y-data.html
    # -> MISS ... plus suggestions

.EXAMPLE
    ./resolve.ps1 buffer -Area tool-reference
#>
[CmdletBinding(DefaultParameterSetName = 'Search')]
param(
    [Parameter(ParameterSetName = 'Search', Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Keywords,

    [Parameter(ParameterSetName = 'Check', Mandatory = $true)]
    [string]$Check,

    [Parameter(ParameterSetName = 'Folder', Mandatory = $true)]
    [string]$Folder,

    [Parameter(ParameterSetName = 'Search')]
    [ValidateSet('any', 'help', 'tool-reference', 'arcpy')]
    [string]$Area = 'any',

    [Parameter(ParameterSetName = 'Search')]
    [switch]$Any,

    [Parameter(ParameterSetName = 'Search')]
    [Parameter(ParameterSetName = 'Folder')]
    [ValidateRange(1, 500)]
    [int]$Limit = 15,

    [ValidateRange(0, 3650)]
    [int]$MaxAgeDays = 7,

    [switch]$Refresh,

    [switch]$Versioned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SitemapUri = 'https://doc.esri.com/en/arcgis-pro/latest/sitemap.xml'
$CachePath  = Join-Path $env:TEMP 'pro_sitemap.xml'

function Get-SitemapFile {
    param([string]$Uri, [string]$Path, [int]$MaxAgeDays, [switch]$Refresh)

    $stale = $true
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        $age = (Get-Date) - $item.LastWriteTime
        if (-not $Refresh -and $item.Length -gt 100000 -and $age.TotalDays -lt $MaxAgeDays) {
            $stale = $false
        }
    }

    if ($stale) {
        Write-Verbose "Downloading $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing
    }

    return Get-Item -LiteralPath $Path
}

function Get-RelativePath {
    param([string]$Url)
    # Strip scheme, host and version segment -> 'help/...' style path.
    return ($Url -replace '^https?://[^/]+/en/arcgis-pro/[^/]+/', '')
}

function Get-SearchHaystack {
    param([string]$Text)
    # Normalise separators so 'x-y', 'x y' and 'x_y' all compare equal.
    return (($Text.ToLowerInvariant() -replace '[-_/.]', ' ') -replace '\s+', ' ')
}

function Get-SquashedText {
    param([string]$Text)
    # Drop separators entirely so 'xy' and 'x-y' compare equal.
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Test-KeywordMatch {
    param([pscustomobject]$Entry, [string]$Token)
    if ($Entry.Haystack -like "*$Token*") { return $true }
    $squashedToken = Get-SquashedText $Token
    if ($squashedToken -and $Entry.Squashed -like "*$squashedToken*") { return $true }
    return $false
}

function Test-LeafWordMatch {
    param([pscustomobject]$Entry, [string]$Token)
    # True when the token matches a word in the page filename ('graphic' -> 'graphics').
    foreach ($word in $Entry.LeafWords) {
        if ($word -eq $Token) { return $true }
        if ($Token.Length -ge 4 -and $word.StartsWith($Token, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$file = Get-SitemapFile -Uri $SitemapUri -Path $CachePath -MaxAgeDays $MaxAgeDays -Refresh:$Refresh
$raw = Get-Content -LiteralPath $file.FullName -Raw

$entries = foreach ($m in [regex]::Matches($raw, '<loc>([^<]+)</loc>')) {
    $url = $m.Groups[1].Value.Trim()
    if ($url -match '/en/arcgis-pro/') {
        $relative = Get-RelativePath $url
        $leaf = (($relative -split '/')[-1]) -replace '\.html$', ''
        [pscustomobject]@{
            Url       = $url
            Relative  = $relative
            Leaf      = $leaf
            LeafWords = @($leaf -split '[-_]+' | Where-Object { $_ })
            Haystack  = Get-SearchHaystack $relative
            Squashed  = Get-SquashedText $relative
        }
    }
}

if ($entries.Count -eq 0) {
    throw "No ArcGIS Pro pages found in $($file.FullName). Try -Refresh."
}

if ($PSCmdlet.ParameterSetName -eq 'Check') {
    $needle = $Check.Trim()
    if ($needle -match '^https?://') { $needle = Get-RelativePath $needle }
    $needle = ($needle -replace '^/', '') -replace '\.htm$', '.html'

    $hit = $entries | Where-Object { $_.Relative -eq $needle } | Select-Object -First 1

    if ($hit) {
        'FOUND' + "`t" + $hit.Url
        exit 0
    }

    'MISS' + "`t" + $needle

    # Near-miss suggestions: weight filename tokens by rarity and rank by coverage.
    $leaf = Split-Path -Leaf $needle
    $tokens = @($leaf -replace '\.html$', '' -split '-' | Where-Object { $_.Length -ge 4 })
    if ($tokens.Count -gt 0) {
        $weights = @{}
        $totalWeight = 0.0
        foreach ($t in $tokens) {
            $df = 0
            foreach ($e in $entries) { if (Test-KeywordMatch -Entry $e -Token $t) { $df++ } }
            if ($df -eq 0) { $df = 1 }
            $w = 1 + [math]::Log([double]$entries.Count / $df)
            $weights[$t] = $w
            $totalWeight += $w
        }

        $suggestions = $entries |
            ForEach-Object {
                $entry = $_
                $score = 0.0
                foreach ($t in $tokens) {
                    if (Test-KeywordMatch -Entry $entry -Token $t) { $score += $weights[$t] }
                }
                $coverage = $score / $totalWeight
                if ($coverage -ge 0.85) {
                    [pscustomobject]@{ Coverage = [math]::Round($coverage, 2); Item = $entry }
                }
            } |
            Sort-Object -Property @{ Expression = 'Coverage'; Descending = $true },
                                  @{ Expression = { $_.Item.Relative.Length }; Descending = $false } |
            Select-Object -First $Limit

        if ($suggestions) {
            ''
            'Near misses:'
            $suggestions | ForEach-Object { '  ' + $_.Item.Relative }
        }
    }

    exit 1
}

if ($PSCmdlet.ParameterSetName -eq 'Folder') {
    $prefix = ($Folder.Trim() -replace '^https?://[^/]+/en/arcgis-pro/[^/]+/', '') -replace '^/', ''
    $listing = $entries |
        Where-Object { $_.Relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object -Property { $_.Relative.Length } |
        Select-Object -First $Limit

    if (-not $listing) {
        "No pages under: $prefix"
        exit 1
    }

    foreach ($row in $listing) {
        if ($Versioned) { $row.Url }
        else { $row.Url -replace '/en/arcgis-pro/[^/]+/', '/en/arcgis-pro/latest/' }
    }
    exit 0
}

if (-not $Keywords -or $Keywords.Count -eq 0) {
    Write-Host 'usage: resolve.ps1 <keywords...>  |  resolve.ps1 -Check <path>  |  resolve.ps1 -Folder <path>'
    exit 2
}

$tokens = @(
    ($Keywords -join ' ') -split '[\s,+]+' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ }
)

if ($tokens.Count -eq 0) {
    Write-Error 'Supply at least one keyword.'
    exit 2
}

$areaPattern = switch ($Area) {
    'help'           { '^help/' }
    'tool-reference' { '^tool-reference/' }
    'arcpy'          { '^arcpy/' }
    default          { '^' }
}

$candidates = $entries | Where-Object {
    if ($_.Relative -notmatch $areaPattern) { return $false }
    $entry = $_
    $matched = 0
    foreach ($t in $tokens) {
        if (Test-KeywordMatch -Entry $entry -Token $t) { $matched++ }
        elseif (-not $Any) { return $false }
    }
    return ($matched -gt 0)
}

$ranked = $candidates |
    ForEach-Object {
        $entry = $_
        $score = 0
        $leafHits = 0
        foreach ($t in $tokens) {
            if (Test-KeywordMatch -Entry $entry -Token $t) {
                $score++
                if (Test-LeafWordMatch -Entry $entry -Token $t) { $leafHits++ }
            }
        }
        [pscustomobject]@{ Score = $score; LeafHits = $leafHits; Item = $entry }
    } |
    Sort-Object -Property @{ Expression = 'Score'; Descending = $true },
                          @{ Expression = 'LeafHits'; Descending = $true },
                          @{ Expression = { $_.Item.Relative.Length }; Descending = $false } |
    Select-Object -First $Limit

if (-not $ranked) {
    "No page matched: $($tokens -join ' ')"
    exit 1
}

foreach ($row in $ranked) {
    if ($Versioned) {
        $row.Item.Url
    }
    else {
        $row.Item.Url -replace '/en/arcgis-pro/[^/]+/', '/en/arcgis-pro/latest/'
    }
}

exit 0
