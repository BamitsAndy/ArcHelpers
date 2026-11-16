#Requires -Version 7.0
<#
.SYNOPSIS
    Resolve ArcGIS Pro help page URLs from the vendor sitemap. Never guess a path.

.DESCRIPTION
    The doc.esri.com table of contents is rendered client-side, so help pages cannot be
    reached by crawling. The sitemap lists every published page; it is cached raw at
    <project>/.cache/pro-help/sitemap.xml and regex-searched in a single pass.

    Keyword mode : all keywords must appear in the URL; filename matches rank first.
    -Check mode  : validate one exact path or URL; suggests near misses on failure.
    -Folder mode : list the shortest page paths under a prefix.

.EXAMPLE
    ./resolve.ps1 xy coordinate data

.EXAMPLE
    ./resolve.ps1 -Check help/mapping/layer-properties/x-y-data.html

.EXAMPLE
    ./resolve.ps1 buffer -Area tool-reference -Versioned
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
    [Parameter(ParameterSetName = 'Check')]
    [ValidateRange(1, 500)]
    [int]$Limit = 15,

    [ValidateRange(0, 3650)]
    [int]$MaxAgeDays = 7,

    [switch]$Refresh,

    [switch]$Versioned,

    [string]$CacheDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SitemapUri = 'https://doc.esri.com/en/arcgis-pro/latest/sitemap.xml'
$MinSitemapBytes = 1000000

function Write-WarningLine {
    param([string]$Message)
    # Console.Error keeps stdout reserved for results (agent parses it directly).
    [Console]::Error.WriteLine("WARNING: $Message")
}

function New-CacheDirectory {
    param([string]$Preferred)

    try {
        if (-not (Test-Path -LiteralPath $Preferred)) {
            New-Item -ItemType Directory -Path $Preferred -Force | Out-Null
        }
        $probe = Join-Path $Preferred ('.probe-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        return $Preferred
    }
    catch {
        $fallback = Join-Path $env:TEMP 'pro-help'
        if ($Preferred -ne $fallback) {
            Write-WarningLine "Cache directory '$Preferred' is not writable; using '$fallback'."
            if (-not (Test-Path -LiteralPath $fallback)) {
                New-Item -ItemType Directory -Path $fallback -Force | Out-Null
            }
            return $fallback
        }
        throw
    }
}

function Resolve-CacheDirectory {
    param([string]$Override)

    if ($Override) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Override)
        return New-CacheDirectory -Preferred ([IO.Path]::GetFullPath($expanded))
    }

    $dir = $PSScriptRoot
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.opencode') -PathType Container) {
            return New-CacheDirectory -Preferred (Join-Path $dir '.cache\pro-help')
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return New-CacheDirectory -Preferred (Join-Path $env:TEMP 'pro-help')
}

function Invoke-SitemapDownload {
    param([string]$Uri, [string]$Path)

    $tempPath = "$Path.download"
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $tempPath -UseBasicParsing -TimeoutSec 60
        $text = [IO.File]::ReadAllText($tempPath)
        $count = Get-LocCount $text
        if ($count -lt 10000 -or $count -gt 100000 -or $text -notmatch '/en/arcgis-pro/') {
            throw "Downloaded sitemap failed validation ($count <loc> entries)."
        }
        Move-Item -LiteralPath $tempPath -Force -Destination $Path
    }
    finally {
        $ProgressPreference = $progress
        # Success moves the file; a failed or rejected download leaves no debris.
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SitemapFile {
    param([string]$Uri, [string]$Path, [int]$MaxAgeDays, [switch]$Refresh)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $item = Get-Item -LiteralPath $Path
        $age = (Get-Date) - $item.LastWriteTime
        if (-not $Refresh -and $item.Length -gt $MinSitemapBytes -and $age.TotalDays -lt $MaxAgeDays) {
            return $Path
        }
    }

    try {
        Invoke-SitemapDownload -Uri $Uri -Path $Path
        return $Path
    }
    catch {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $Path
            if ($item.Length -gt $MinSitemapBytes) {
                Write-WarningLine "Download failed ($($_.Exception.Message)); using cached sitemap from $($item.LastWriteTime)."
                return $Path
            }
        }
        throw "Cannot download the sitemap from $Uri and no usable cache exists at $Path. Check your connection, or retry with -Refresh. $($_.Exception.Message)"
    }
}

function Format-Url {
    param([string]$Url)
    if ($Versioned) { return $Url }
    return ($Url -replace '/en/arcgis-pro/[^/]+/', '/en/arcgis-pro/latest/')
}

function Get-RelativePath {
    param([string]$Url)
    return ($Url -replace '^https?://[^/]+/en/arcgis-pro/[^/]+/', '')
}

function Get-TokenPattern {
    param([string]$Token)
    # Separator-tolerant: 'x-y' and 'xy' produce the same pattern.
    $chars = [regex]::Replace($Token.ToLowerInvariant(), '[-_/. ]+', '')
    if (-not $chars) { return $null }
    $parts = foreach ($c in $chars.ToCharArray()) { [regex]::Escape([string]$c) }
    return ($parts -join '[-_/. ]?')
}

function Get-LocCount {
    param([string]$Text)
    # One string replace instead of 16k regex matches; '<loc>' never nests.
    return [int](($Text.Length - $Text.Replace('<loc>', '').Length) / 5)
}

function Get-BigramDice {
    param([string]$Left, [string]$Right)

    $a = $Left.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $b = $Right.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($a.Length -lt 2 -or $b.Length -lt 2) {
        if ($a -eq $b) { return 1.0 }
        return 0.0
    }

    $counts = @{}
    for ($i = 0; $i -lt $a.Length - 1; $i++) {
        $gram = $a.Substring($i, 2)
        if ($counts.ContainsKey($gram)) { $counts[$gram]++ } else { $counts[$gram] = 1 }
    }
    $shared = 0
    for ($i = 0; $i -lt $b.Length - 1; $i++) {
        $gram = $b.Substring($i, 2)
        if ($counts.ContainsKey($gram) -and $counts[$gram] -gt 0) {
            $counts[$gram]--
            $shared++
        }
    }
    return (2.0 * $shared) / (($a.Length - 1) + ($b.Length - 1))
}

$cacheDir = Resolve-CacheDirectory -Override $CacheDir
$cachePath = Join-Path $cacheDir 'sitemap.xml'

try {
    $sitemapPath = Get-SitemapFile -Uri $SitemapUri -Path $cachePath -MaxAgeDays $MaxAgeDays -Refresh:$Refresh
}
catch {
    [Console]::Error.WriteLine("resolve: $($_.Exception.Message)")
    exit 2
}

$raw = [IO.File]::ReadAllText($sitemapPath)
$locCount = Get-LocCount $raw
if ($locCount -lt 10000) {
    [Console]::Error.WriteLine("resolve: sitemap at $sitemapPath looks corrupt ($locCount <loc> entries). Re-run with -Refresh.")
    exit 2
}

if ($PSCmdlet.ParameterSetName -eq 'Check') {
    $needle = $Check.Trim()
    $needle = ($needle -split '[?#]')[0]
    if ($needle -match '^https?://') {
        $needle = Get-RelativePath $needle
    }
    $needle = $needle -replace '^/', ''
    $needle = $needle -replace '\.htm$', '.html'

    # Fast exact hit: ordinal-ignore-case substring scan, then confirm the hit is a whole
    # <loc> path. (~15 ms instead of a 200 ms regex sweep.)
    $hitUrl = $null
    $at = $raw.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase)
    while ($at -ge 0 -and -not $hitUrl) {
        $open = $raw.LastIndexOf('<loc>', $at, [System.StringComparison]::Ordinal)
        $close = $raw.IndexOf('</loc>', $at, [System.StringComparison]::Ordinal)
        if ($open -ge 0 -and $close -gt $at) {
            $candidateUrl = $raw.Substring($open + 5, $close - $open - 5)
            if ((Get-RelativePath $candidateUrl) -eq $needle) { $hitUrl = $candidateUrl }
        }
        if (-not $hitUrl) {
            $next = $at + 1
            if ($next -ge $raw.Length) { break }
            $at = $raw.IndexOf($needle, $next, [System.StringComparison]::OrdinalIgnoreCase)
        }
    }

    if ($hitUrl) {
        'FOUND' + "`t" + (Format-Url ([System.Net.WebUtility]::HtmlDecode($hitUrl)))
        exit 0
    }

    'MISS' + "`t" + $needle

    $suggestionLimit = if ($PSBoundParameters.ContainsKey('Limit')) { $Limit } else { 5 }
    $folder = ''
    $leaf = $needle
    $cut = $needle.LastIndexOf('/')
    if ($cut -ge 0) {
        $folder = $needle.Substring(0, $cut + 1)
        $leaf = $needle.Substring($cut + 1)
    }
    $leafStem = $leaf -replace '\.html$', ''

    $pool = @()
    if ($folder) {
        $folderPattern = '(?i)<loc>(https?://[^/]+/en/arcgis-pro/[^/]+/' + [regex]::Escape($folder) + '[^<]+)</loc>'
        $pool = @([regex]::Matches($raw, $folderPattern) | ForEach-Object {
                $url = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
                [pscustomobject]@{ Url = $url; Relative = (Get-RelativePath $url) }
            })
    }

    if ($pool.Count -lt 2) {
        $fallbackTokens = @($leafStem -split '[-_]+' | Where-Object { $_.Length -ge 4 })
        if ($fallbackTokens.Count -gt 0) {
            $fallbackPatterns = @($fallbackTokens | ForEach-Object { Get-TokenPattern $_ } | Where-Object { $_ })
            $fallbackPattern = '(?i)<loc>(https?://[^/]+/en/arcgis-pro/[^/]+/(?=[^<]*(?:' +
                ($fallbackPatterns -join '|') + '))[^<]+)</loc>'
            $pool = @([regex]::Matches($raw, $fallbackPattern) | ForEach-Object {
                    $url = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
                    [pscustomobject]@{ Url = $url; Relative = (Get-RelativePath $url) }
                })
        }
    }

    $suggestions = @($pool |
            ForEach-Object {
                [pscustomobject]@{
                    Dice     = Get-BigramDice $leafStem (($_.Relative -split '/')[-1] -replace '\.html$', '')
                    Length   = $_.Relative.Length
                    Relative = $_.Relative
                }
            } |
            Sort-Object -Property @{ Expression = 'Dice'; Descending = $true },
                                  @{ Expression = 'Length'; Descending = $false },
                                  @{ Expression = 'Relative'; Descending = $false } |
            Select-Object -First $suggestionLimit)

    if ($suggestions.Count -gt 0) {
        ''
        'Near misses:'
        $suggestions | ForEach-Object { '  ' + $_.Relative }
    }
    exit 1
}

if ($PSCmdlet.ParameterSetName -eq 'Folder') {
    $prefix = $Folder.Trim()
    if ($prefix -match '^https?://') { $prefix = Get-RelativePath $prefix }
    $prefix = $prefix -replace '^/', ''

    $folderPattern = '(?i)<loc>(https?://[^/]+/en/arcgis-pro/[^/]+/' + [regex]::Escape($prefix) + '[^<]*)</loc>'
    $listing = @([regex]::Matches($raw, $folderPattern) | ForEach-Object {
            $url = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
            [pscustomobject]@{ Url = $url; Relative = (Get-RelativePath $url) }
        } |
        Sort-Object -Property @{ Expression = { $_.Relative.Length } },
                              @{ Expression = { $_.Relative } } |
        Select-Object -First $Limit)

    if ($listing.Count -eq 0) {
        "No pages under: $prefix"
        exit 1
    }

    foreach ($row in $listing) { Format-Url $row.Url }
    exit 0
}

$tokens = @(
    ($Keywords -join ' ') -split '[\s,+]+' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ }
)
$patterns = @($tokens | ForEach-Object { Get-TokenPattern $_ } | Where-Object { $_ })
$cores = @($tokens | ForEach-Object { [regex]::Replace($_, '[-_/. ]+', '') } | Where-Object { $_ })

if ($patterns.Count -eq 0) {
    'usage: resolve.ps1 <keywords...>  |  resolve.ps1 -Check <path>  |  resolve.ps1 -Folder <path>'
    exit 2
}

$areaPrefix = switch ($Area) {
    'help' { 'help/' }
    'tool-reference' { 'tool-reference/' }
    'arcpy' { 'arcpy/' }
    default { '' }
}

$base = '(?i)<loc>(https?://[^/]+/en/arcgis-pro/[^/]+/' + [regex]::Escape($areaPrefix)
if ($Any) {
    $lookahead = '(?=[^<]*(?:' + ($patterns -join '|') + '))'
}
else {
    $lookahead = (@($patterns | ForEach-Object { '(?=[^<]*' + $_ + ')' }) -join '')
}

$tokenRegexes = @($patterns | ForEach-Object {
        [regex]::new($_, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    })

$ranked = @([regex]::Matches($raw, $base + $lookahead + '[^<]+)</loc>') |
        ForEach-Object {
            $url = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
            $relative = Get-RelativePath $url
            $leafWords = (($relative -split '/')[-1] -replace '\.html$', '') -split '[-_]+'
            $score = 0
            $leafHits = 0
            for ($i = 0; $i -lt $tokenRegexes.Count; $i++) {
                if (-not $tokenRegexes[$i].IsMatch($relative)) { continue }
                $score++
                $core = $cores[$i]
                foreach ($word in $leafWords) {
                    if ($word -eq $core -or ($core.Length -ge 4 -and $word.StartsWith($core, [System.StringComparison]::OrdinalIgnoreCase))) {
                        $leafHits++
                        break
                    }
                }
            }
            [pscustomobject]@{
                Score    = $score
                LeafHits = $leafHits
                Length   = $relative.Length
                Relative = $relative
                Url      = $url
            }
        } |
    Sort-Object -Property @{ Expression = 'Score'; Descending = $true },
                          @{ Expression = 'LeafHits'; Descending = $true },
                          @{ Expression = 'Length'; Descending = $false },
                          @{ Expression = 'Relative'; Descending = $false } |
    Select-Object -First $Limit)

if ($ranked.Count -eq 0) {
    "No page matched: $($tokens -join ' ')"
    exit 1
}

foreach ($row in $ranked) { Format-Url $row.Url }
exit 0
