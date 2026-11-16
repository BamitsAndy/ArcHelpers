#Requires -Version 7.0
<#
.SYNOPSIS
    Golden-query harness for resolve.ps1. Developer tool only; SKILL.md does not use it.

.DESCRIPTION
    Runs the corpus agreed for the v2 resolver and checks stdout, exit codes and warm
    timings. Exit code 0 means every case passed.

.EXAMPLE
    pwsh -NoProfile -File .opencode/skills/pro-help-v2/scripts/selftest.ps1

.EXAMPLE
    pwsh -NoProfile -File .opencode/skills/pro-help-v2/scripts/selftest.ps1 -SkipTiming
#>
[CmdletBinding()]
param(
    [string]$CacheDir,
    [switch]$SkipTiming
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolver = Join-Path $PSScriptRoot 'resolve.ps1'
$cacheArgs = if ($CacheDir) { @('-CacheDir', $CacheDir) } else { @() }

$cases = @(
    @{ Name = 'keyword: xy coordinate data'
        Args = @('xy', 'coordinate', 'data'); Exit = 0; Count = 3; First = 'add-xy-coordinates\.html'
        Contains = @('layer-properties/add-x-y-coordinate-data-as-a-layer\.html') }
    @{ Name = 'keyword: circle -Area help'
        Args = @('circle', '-Area', 'help'); Exit = 0; Count = 2; First = 'create-circles-and-ellipses\.html' }
    @{ Name = 'keyword: buffer -Area tool-reference'
        Args = @('buffer', '-Area', 'tool-reference'); Exit = 0; First = 'tool-reference/analysis/buffer\.html' }
    @{ Name = 'keyword: create polygon features'
        Args = @('create', 'polygon', 'features'); Exit = 0; First = 'help/editing/create-polygon-features\.html' }
    @{ Name = 'keyword: graphic layer'
        Args = @('graphic', 'layer'); Exit = 0; First = 'graphics-layers\.html' }
    @{ Name = 'keyword: graphics -Any'
        Args = @('graphics', '-Any'); Exit = 0; Contains = @('graphics-layers\.html') }
    @{ Name = 'keyword: -Limit'
        Args = @('layer', '-Limit', '3'); Exit = 0; Count = 3 }
    @{ Name = 'check: known page'
        Args = @('-Check', 'help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html')
        Exit = 0; First = '^FOUND' }
    @{ Name = 'check: .htm accepted'
        Args = @('-Check', 'https://doc.esri.com/en/arcgis-pro/3.7/tool-reference/analysis/buffer.htm')
        Exit = 0; First = '^FOUND.*latest/tool-reference/analysis/buffer\.html$' }
    @{ Name = 'check: near miss'
        Args = @('-Check', 'help/mapping/layer-properties/x-y-data.html')
        Exit = 1; First = '^MISS'; Contains = @('Near misses:', 'add-x-y-coordinate-data-as-a-layer\.html') }
    @{ Name = 'folder: help/editing'
        Args = @('-Folder', 'help/editing', '-Limit', '10'); Exit = 0; Count = 10 }
    @{ Name = 'versioned: buffer'
        Args = @('buffer', '-Versioned'); Exit = 0; Contains = @('/arcgis-pro/3\.7/')
        Excludes = @('/latest/') }
    @{ Name = 'keyword: no match'
        Args = @('zzzzqqq'); Exit = 1; First = '^No page matched' }
    @{ Name = 'usage: no arguments'
        Args = @(); Exit = 2; First = '^usage:' }
)

function Test-Case {
    param([hashtable]$Case)

    $lines = @()
    $code = 0
    $ms = 0
    $argv = @($Case.Args) + @($cacheArgs)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Run as a child process: it mirrors how an agent calls the script and avoids
        # in-process array-splat binding quirks with named parameters such as -Area.
        $lines = @(& pwsh -NoProfile -File $resolver @argv 2>$null)
        $code = $LASTEXITCODE
    }
    catch {
        $lines = @("ERROR: $($_.Exception.Message)")
    }
    finally {
        $sw.Stop()
        $ms = [math]::Round($sw.Elapsed.TotalMilliseconds)
    }

    $problems = @()
    if ($code -ne $Case.Exit) { $problems += "exit $code (expected $($Case.Exit))" }
    if ($Case.ContainsKey('Count') -and $Case.Count -ne $lines.Count) {
        $problems += "$($lines.Count) lines (expected $($Case.Count))"
    }
    if ($Case.ContainsKey('First') -and ($lines.Count -eq 0 -or $lines[0] -notmatch $Case.First)) {
        $problems += "first line '$($lines | Select-Object -First 1)' does not match /$($Case.First)/"
    }
    if ($Case.ContainsKey('Contains')) {
        foreach ($pattern in @($Case.Contains)) {
            if (-not ($lines -match $pattern)) { $problems += "missing /$pattern/" }
        }
    }
    if ($Case.ContainsKey('Excludes')) {
        foreach ($pattern in @($Case.Excludes)) {
            if ($lines -match $pattern) { $problems += "unexpected /$pattern/" }
        }
    }

    [pscustomobject]@{ Name = $Case.Name; Ms = $ms; Problems = $problems }
}

$results = foreach ($case in $cases) { Test-Case -Case $case }

$failed = 0
foreach ($r in $results) {
    if ($r.Problems.Count -eq 0) {
        'PASS  {0,-42} {1,6} ms' -f $r.Name, $r.Ms
    }
    else {
        $failed++
        'FAIL  {0,-42} {1,6} ms  {2}' -f $r.Name, $r.Ms, ($r.Problems -join '; ')
    }
}

'' 
'{0} passed, {1} failed' -f ($results.Count - $failed), $failed
if (-not $SkipTiming) {
    'slowest: {0} ms ({1})' -f ($results | Measure-Object -Property Ms -Maximum).Maximum,
        ($results | Sort-Object -Property Ms -Descending | Select-Object -First 1).Name
}
exit ([int]($failed -gt 0))
