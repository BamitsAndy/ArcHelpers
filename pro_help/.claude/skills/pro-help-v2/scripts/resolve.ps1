#Requires -Version 5.1
<#
.SYNOPSIS
    Resolve ArcGIS Pro help page URLs from the vendor sitemap. Never guess a path.

.DESCRIPTION
    The doc.esri.com table of contents is rendered client-side, so help pages cannot be
    reached by crawling. The sitemap lists every published page; it is cached at
    <project>/.cache/pro-help/sitemap.xml and reduced once into paths.txt - one relative
    path per line, LF-terminated - which every later search scans in a single regex pass.

    Output contract: stdout carries nothing but fetchable URLs, one per line. Every
    diagnostic (MISS, near misses, no-match, usage, warnings) goes to stderr. The exit
    code is the verdict: 0 = at least one URL on stdout, 1 = nothing matched, 2 = usage
    error or hard failure.

    Keyword mode : all keywords must appear in the path; filename matches rank first.
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
    [int]$Limit = 8,

    [ValidateRange(0, 3650)]
    [int]$MaxAgeDays = 7,

    [switch]$Refresh,

    [switch]$Versioned,

    [string]$CacheDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 6) {
    # Windows PowerShell 5.1 still defaults to TLS 1.0, which doc.esri.com rejects.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

$SitemapUri = 'https://doc.esri.com/en/arcgis-pro/latest/sitemap.xml'
$MinSitemapBytes = 1000000
$MinIndexBytes = 200000
$MinLocCount = 10000
$MaxLocCount = 100000
# Candidate scoring is a PowerShell loop, so bound it. Only reached on a -Check miss.
$MaxSuggestionPool = 1500
$LF = [string][char]10

function Write-Diag {
    param([string]$Message = '')
    # stdout is reserved for fetchable URLs; everything else goes here.
    [Console]::Error.WriteLine($Message)
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
        # GetTempPath is always defined; $env:TEMP is not set on Linux or macOS.
        $fallback = Join-Path ([IO.Path]::GetTempPath()) 'pro-help'
        if ($Preferred -ne $fallback) {
            Write-Diag "WARNING: cache directory '$Preferred' is not writable; using '$fallback'."
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

    # Any one of these marks a project root, so the cache lands in the project whether
    # the skill is installed for Claude Code, OpenCode, or neither.
    $markers = @('.claude', '.opencode', '.git')
    $dir = $PSScriptRoot
    while ($dir) {
        foreach ($marker in $markers) {
            if (Test-Path -LiteralPath (Join-Path $dir $marker)) {
                return New-CacheDirectory -Preferred (Join-Path (Join-Path $dir '.cache') 'pro-help')
            }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return New-CacheDirectory -Preferred (Join-Path ([IO.Path]::GetTempPath()) 'pro-help')
}

function Get-LocCount {
    param([string]$Text)
    # One string replace instead of 16k regex matches; '<loc>' never nests.
    return [int](($Text.Length - $Text.Replace('<loc>', '').Length) / 5)
}

function Invoke-SitemapDownload {
    param([string]$Uri, [string]$Path)

    # Per-process temp name: the Claude and OpenCode copies share one cache directory,
    # so two resolvers can race on a cold cache.
    $tempPath = "$Path.$PID.download"
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $tempPath -UseBasicParsing -TimeoutSec 60
        $text = [IO.File]::ReadAllText($tempPath)
        $count = Get-LocCount $text
        if ($count -lt $MinLocCount -or $count -gt $MaxLocCount -or $text -notmatch '/en/arcgis-pro/') {
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
                Write-Diag "WARNING: download failed ($($_.Exception.Message)); using cached sitemap from $($item.LastWriteTime)."
                return $Path
            }
        }
        throw "Cannot download the sitemap from $Uri and no usable cache exists at $Path. Check your connection, or retry with -Refresh. $($_.Exception.Message)"
    }
}

function New-PathIndex {
    param([string]$SitemapPath, [string]$IndexPath)

    $raw = [IO.File]::ReadAllText($SitemapPath)
    $count = Get-LocCount $raw
    if ($count -lt $MinLocCount) {
        throw "sitemap at $SitemapPath looks corrupt ($count <loc> entries). Re-run with -Refresh."
    }

    $base = $null
    $skipped = 0
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($raw, '(?i)<loc>(https?://[^/]+/en/arcgis-pro/[^/]+/)([^<]*)</loc>')) {
        $thisBase = $match.Groups[1].Value
        if (-not $base) { $base = $thisBase }
        if ($thisBase -ne $base) { $skipped++; continue }
        $relative = [Net.WebUtility]::HtmlDecode($match.Groups[2].Value)
        if ($relative) { $paths.Add($relative) }
    }

    if (-not $base -or $paths.Count -lt $MinLocCount) {
        throw "sitemap at $SitemapPath yielded only $($paths.Count) usable paths. Re-run with -Refresh."
    }
    if ($skipped -gt 0) {
        Write-Diag "WARNING: skipped $skipped sitemap entries from a base other than $base."
    }

    # LF only: .NET's multiline '$' does not match between CR and LF.
    $text = $base + $LF + ($paths -join $LF) + $LF
    $tempPath = "$IndexPath.$PID.tmp"
    try {
        [IO.File]::WriteAllText($tempPath, $text)
        Move-Item -LiteralPath $tempPath -Force -Destination $IndexPath
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PathIndex {
    param([string]$SitemapPath, [string]$IndexPath)

    if (Test-Path -LiteralPath $IndexPath -PathType Leaf) {
        $index = Get-Item -LiteralPath $IndexPath
        $sitemap = Get-Item -LiteralPath $SitemapPath
        if ($index.Length -gt $MinIndexBytes -and $index.LastWriteTime -ge $sitemap.LastWriteTime) {
            return $IndexPath
        }
    }
    New-PathIndex -SitemapPath $SitemapPath -IndexPath $IndexPath
    return $IndexPath
}

function Format-Url {
    param([string]$Relative)
    return $script:outBase + $Relative
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

function New-BigramSet {
    param([string]$Text)

    $norm = $Text.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $norm.Length - 1; $i++) {
        [void]$set.Add($norm.Substring($i, 2))
    }
    return [pscustomobject]@{ Set = $set; Norm = $norm; Length = $norm.Length }
}

function Get-BigramDice {
    param($LeftSet, [string]$Right)

    # The left side is built once per run, so scoring a candidate allocates nothing.
    $right = $Right.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if ($LeftSet.Length -lt 2 -or $right.Length -lt 2) {
        if ($LeftSet.Norm -eq $right) { return 1.0 }
        return 0.0
    }
    $shared = 0
    for ($i = 0; $i -lt $right.Length - 1; $i++) {
        if ($LeftSet.Set.Contains($right.Substring($i, 2))) { $shared++ }
    }
    return (2.0 * $shared) / (($LeftSet.Length - 1) + ($right.Length - 1))
}

function Select-ScoredPool {
    param([string[]]$Pool, [string]$Stem, [int]$Take)

    $pruned = $Pool
    if ($pruned.Count -gt $MaxSuggestionPool) {
        Write-Diag "note: $($pruned.Count) candidates; scoring the $MaxSuggestionPool shortest."
        $pruned = @($pruned | Sort-Object -Property Length | Select-Object -First $MaxSuggestionPool)
    }

    $leftSet = New-BigramSet $Stem
    return @($pruned |
            ForEach-Object {
                [pscustomobject]@{
                    Dice     = Get-BigramDice $leftSet ((($_ -split '/')[-1]) -replace '\.html$', '')
                    Length   = $_.Length
                    Relative = $_
                }
            } |
            Sort-Object -Property @{ Expression = 'Dice'; Descending = $true },
                                  @{ Expression = 'Length'; Descending = $false },
                                  @{ Expression = 'Relative'; Descending = $false } |
            Select-Object -First $Take)
}

$cacheDir = Resolve-CacheDirectory -Override $CacheDir
$cachePath = Join-Path $cacheDir 'sitemap.xml'
$indexPath = Join-Path $cacheDir 'paths.txt'

try {
    $sitemapPath = Get-SitemapFile -Uri $SitemapUri -Path $cachePath -MaxAgeDays $MaxAgeDays -Refresh:$Refresh
    $indexPath = Get-PathIndex -SitemapPath $sitemapPath -IndexPath $indexPath
}
catch {
    Write-Diag "resolve: $($_.Exception.Message)"
    exit 2
}

# Line 1 is the versioned base URL; every later line is one relative path.
$indexText = [IO.File]::ReadAllText($indexPath)
$split = $indexText.IndexOf($LF)
if ($split -lt 1 -or $indexText.Length -lt $MinIndexBytes) {
    Write-Diag "resolve: path index at $indexPath is unusable. Re-run with -Refresh."
    exit 2
}
$baseUrl = $indexText.Substring(0, $split)
$body = $indexText.Substring($split + 1)
$outBase = if ($Versioned) { $baseUrl } else { $baseUrl -replace '/en/arcgis-pro/[^/]+/', '/en/arcgis-pro/latest/' }

if ($PSCmdlet.ParameterSetName -eq 'Check') {
    $needle = ($Check.Trim() -split '[?#]')[0]
    if ($needle -match '^https?://') { $needle = Get-RelativePath $needle }
    $needle = $needle -replace '^/', ''
    $needle = $needle -replace '\.htm$', '.html'

    # An empty needle used to make IndexOf('') walk the whole index one char at a time.
    if (-not $needle) {
        Write-Diag 'usage: resolve.ps1 -Check <relative-path|url>'
        exit 2
    }

    $exact = [regex]::Match($body, '(?im)^' + [regex]::Escape($needle) + '$')
    if ($exact.Success) {
        Format-Url $exact.Value
        exit 0
    }

    Write-Diag ('MISS' + [char]9 + $needle)

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
        $pool = @([regex]::Matches($body, '(?im)^' + [regex]::Escape($folder) + '[^\r\n]+$') |
                ForEach-Object { $_.Value })
    }

    if ($pool.Count -lt 2) {
        $fallbackTokens = @($leafStem -split '[-_]+' | Where-Object { $_.Length -ge 4 })
        $fallbackPatterns = @($fallbackTokens | ForEach-Object { Get-TokenPattern $_ } | Where-Object { $_ })
        if ($fallbackPatterns.Count -gt 0) {
            # AND first - for a multi-token stem that pool is far smaller than the OR pool.
            $andLookahead = (@($fallbackPatterns | ForEach-Object { '(?=[^\r\n]*' + $_ + ')' }) -join '')
            $pool = @([regex]::Matches($body, '(?im)^' + $andLookahead + '[^\r\n]+$') |
                    ForEach-Object { $_.Value })
            if ($pool.Count -eq 0) {
                $orLookahead = '(?=[^\r\n]*(?:' + ($fallbackPatterns -join '|') + '))'
                $pool = @([regex]::Matches($body, '(?im)^' + $orLookahead + '[^\r\n]+$') |
                        ForEach-Object { $_.Value })
            }
        }
    }

    $suggestions = @()
    if ($pool.Count -gt 0) {
        $suggestions = @(Select-ScoredPool -Pool $pool -Stem $leafStem -Take $suggestionLimit)
    }

    if ($suggestions.Count -gt 0) {
        Write-Diag ''
        Write-Diag 'Near misses:'
        foreach ($row in $suggestions) { Write-Diag ('  ' + $row.Relative) }
    }
    exit 1
}

if ($PSCmdlet.ParameterSetName -eq 'Folder') {
    $prefix = $Folder.Trim()
    if ($prefix -match '^https?://') { $prefix = Get-RelativePath $prefix }
    $prefix = $prefix -replace '^/', ''
    if (-not $prefix) {
        Write-Diag 'usage: resolve.ps1 -Folder <path-prefix>'
        exit 2
    }

    $listing = @([regex]::Matches($body, '(?im)^' + [regex]::Escape($prefix) + '[^\r\n]*$') |
            ForEach-Object { $_.Value } |
            Sort-Object -Property @{ Expression = { $_.Length } },
                                  @{ Expression = { $_ } } |
            ForEach-Object { Format-Url $_ } |
            Select-Object -Unique |
            Select-Object -First $Limit)

    if ($listing.Count -eq 0) {
        Write-Diag "no pages under: $prefix"
        exit 1
    }

    $listing
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
    Write-Diag 'usage: resolve.ps1 <keywords...>  |  resolve.ps1 -Check <path>  |  resolve.ps1 -Folder <path>'
    exit 2
}

$areaPrefix = switch ($Area) {
    'help' { 'help/' }
    'tool-reference' { 'tool-reference/' }
    'arcpy' { 'arcpy/' }
    default { '' }
}

if ($Any) {
    $lookahead = '(?=[^\r\n]*(?:' + ($patterns -join '|') + '))'
}
else {
    $lookahead = (@($patterns | ForEach-Object { '(?=[^\r\n]*' + $_ + ')' }) -join '')
}

$tokenRegexes = @($patterns | ForEach-Object {
        [regex]::new($_, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    })

$ranked = @([regex]::Matches($body, '(?im)^(' + $lookahead + [regex]::Escape($areaPrefix) + '[^\r\n]+)$') |
        ForEach-Object {
            $relative = $_.Groups[1].Value
            $leafWords = (($relative -split '/')[-1] -replace '\.html$', '') -split '[-_]+'
            $score = 0
            $leafHits = 0
            for ($i = 0; $i -lt $tokenRegexes.Count; $i++) {
                if (-not $tokenRegexes[$i].IsMatch($relative)) { continue }
                $score++
                $core = $cores[$i]
                foreach ($word in $leafWords) {
                    if ($word -eq $core -or ($core.Length -ge 4 -and $word.StartsWith($core, [StringComparison]::OrdinalIgnoreCase))) {
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
            }
        } |
    Sort-Object -Property @{ Expression = 'Score'; Descending = $true },
                          @{ Expression = 'LeafHits'; Descending = $true },
                          @{ Expression = 'Length'; Descending = $false },
                          @{ Expression = 'Relative'; Descending = $false } |
    ForEach-Object { Format-Url $_.Relative } |
    Select-Object -Unique |
    Select-Object -First $Limit)

if ($ranked.Count -eq 0) {
    Write-Diag "no page matched: $($tokens -join ' ')"
    exit 1
}

$ranked
exit 0
