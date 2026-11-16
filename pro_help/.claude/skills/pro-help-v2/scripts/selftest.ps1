#Requires -Version 5.1
<#
.SYNOPSIS
    Golden-query harness for resolve.ps1. Developer tool only; SKILL.md does not use it.

.DESCRIPTION
    Runs the corpus agreed for the v2 resolver and checks stdout, stderr, exit codes and
    warm timings. Exit code 0 means every case passed.

    Assertions avoid exact page counts where the vendor controls the number, so publishing
    a new help page does not fail the suite. Exact counts are asserted only where the count
    is an invariant of the resolver itself (-Limit, and one URL from -Check).

    Every case additionally asserts the output contract: nothing but URLs on stdout.

    The resolver is launched with the same PowerShell host that runs this script, so
    running the suite under powershell.exe tests resolve.ps1 under Windows PowerShell 5.1.

.EXAMPLE
    pwsh -NoProfile -File .claude/skills/pro-help-v2/scripts/selftest.ps1

.EXAMPLE
    powershell -NoProfile -File .claude/skills/pro-help-v2/scripts/selftest.ps1
#>
[CmdletBinding()]
param(
    [string]$CacheDir,
    [string]$PwshPath,
    [switch]$SkipTiming
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolver = Join-Path $PSScriptRoot 'resolve.ps1'
$cacheArgs = if ($CacheDir) { @('-CacheDir', $CacheDir) } else { @() }
$exe = if ($PwshPath) { $PwshPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }

$cases = @(
    @{ Name = 'keyword: xy coordinate data'
        Args = @('xy', 'coordinate', 'data'); Exit = 0; MinCount = 2
        First = 'add-xy-coordinates\.html$'
        Contains = @('layer-properties/add-x-y-coordinate-data-as-a-layer\.html$') }
    @{ Name = 'keyword: circle -Area help'
        Args = @('circle', '-Area', 'help'); Exit = 0; MinCount = 1
        First = 'create-circles-and-ellipses\.html$' }
    @{ Name = 'keyword: buffer -Area tool-reference'
        Args = @('buffer', '-Area', 'tool-reference'); Exit = 0; MinCount = 1
        First = 'tool-reference/analysis/buffer\.html$' }
    @{ Name = 'keyword: create polygon features'
        Args = @('create', 'polygon', 'features'); Exit = 0
        First = 'help/editing/create-polygon-features\.html$' }
    @{ Name = 'keyword: graphic layer'
        Args = @('graphic', 'layer'); Exit = 0; First = 'graphics-layers\.html$' }
    @{ Name = 'keyword: graphics -Any'
        Args = @('graphics', '-Any'); Exit = 0; Contains = @('graphics-layers\.html$') }
    @{ Name = 'keyword: default -Limit is 8'
        Args = @('layer'); Exit = 0; Count = 8 }
    @{ Name = 'keyword: -Limit honoured'
        Args = @('layer', '-Limit', '3'); Exit = 0; Count = 3 }
    @{ Name = 'check: known page'
        Args = @('-Check', 'help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer.html')
        Exit = 0; Count = 1
        First = '^https://doc\.esri\.com/en/arcgis-pro/latest/help/mapping/layer-properties/add-x-y-coordinate-data-as-a-layer\.html$' }
    @{ Name = 'check: .htm and version normalised'
        Args = @('-Check', 'https://doc.esri.com/en/arcgis-pro/3.7/tool-reference/analysis/buffer.htm')
        Exit = 0; Count = 1
        First = '^https://doc\.esri\.com/en/arcgis-pro/latest/tool-reference/analysis/buffer\.html$' }
    @{ Name = 'check: near miss goes to stderr'
        Args = @('-Check', 'help/mapping/layer-properties/x-y-data.html')
        Exit = 1; Count = 0; ErrFirst = '^MISS'
        ErrContains = @('Near misses:', 'add-x-y-coordinate-data-as-a-layer\.html') }
    @{ Name = 'check: empty needle rejected'
        Args = @('-Check', '?'); Exit = 2; Count = 0; ErrFirst = '^usage:' }
    @{ Name = 'folder: help/editing'
        Args = @('-Folder', 'help/editing', '-Limit', '10'); Exit = 0; Count = 10 }
    @{ Name = 'folder: unknown prefix'
        Args = @('-Folder', 'nope/nothing'); Exit = 1; Count = 0; ErrFirst = '^no pages under' }
    @{ Name = 'versioned: buffer'
        Args = @('buffer', '-Versioned'); Exit = 0; Contains = @('/arcgis-pro/\d+\.\d+/')
        Excludes = @('/latest/') }
    @{ Name = 'keyword: no match'
        Args = @('zzzzqqq'); Exit = 1; Count = 0; ErrFirst = '^no page matched' }
    @{ Name = 'usage: no arguments'
        Args = @(); Exit = 2; Count = 0; ErrFirst = '^usage:' }
)

function Invoke-Child {
    param([string]$Exe, [string[]]$Arguments)

    # Read the child's streams directly rather than through PowerShell redirection.
    # Windows PowerShell 5.1 reroutes native stderr through its error pipeline, which
    # prefixes the first line with the command name and appends six lines of
    # ErrorRecord noise; .NET gives the same bytes the process actually wrote on
    # both hosts.
    $quoted = @($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        })

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [Diagnostics.Process]::Start($psi)
    # Start both reads before waiting; a full pipe buffer would otherwise deadlock.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $result = [pscustomobject]@{
        Out  = @($outTask.Result -split "`r?`n" | Where-Object { $_ -ne '' })
        Err  = @($errTask.Result -split "`r?`n" | Where-Object { $_ -ne '' })
        Code = $proc.ExitCode
    }
    $proc.Dispose()
    return $result
}

function Test-Case {
    param([hashtable]$Case)

    $lines = @()
    $errLines = @()
    $code = 0
    $ms = 0
    $argv = @('-NoProfile', '-File', $resolver) + @($Case.Args) + @($cacheArgs)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Run as a child process: it mirrors how an agent calls the script and avoids
        # in-process array-splat binding quirks with named parameters such as -Area.
        $run = Invoke-Child -Exe $exe -Arguments $argv
        $lines = $run.Out
        $errLines = $run.Err
        $code = $run.Code
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

    # The output contract, asserted for every case: stdout carries URLs and nothing else.
    foreach ($line in $lines) {
        if ($line -notmatch '^https://doc\.esri\.com/en/arcgis-pro/') {
            $problems += "non-URL on stdout: '$line'"
        }
    }

    if ($Case.ContainsKey('Count') -and $Case.Count -ne $lines.Count) {
        $problems += "$($lines.Count) lines (expected $($Case.Count))"
    }
    if ($Case.ContainsKey('MinCount') -and $lines.Count -lt $Case.MinCount) {
        $problems += "$($lines.Count) lines (expected at least $($Case.MinCount))"
    }
    if ($Case.ContainsKey('First') -and ($lines.Count -eq 0 -or $lines[0] -notmatch $Case.First)) {
        $problems += "first line '$($lines | Select-Object -First 1)' does not match /$($Case.First)/"
    }
    if ($Case.ContainsKey('Contains')) {
        foreach ($pattern in @($Case.Contains)) {
            if (-not ($lines -match $pattern)) { $problems += "stdout missing /$pattern/" }
        }
    }
    if ($Case.ContainsKey('Excludes')) {
        foreach ($pattern in @($Case.Excludes)) {
            if ($lines -match $pattern) { $problems += "stdout has unexpected /$pattern/" }
        }
    }
    if ($Case.ContainsKey('ErrFirst') -and ($errLines.Count -eq 0 -or $errLines[0] -notmatch $Case.ErrFirst)) {
        $problems += "first stderr line '$($errLines | Select-Object -First 1)' does not match /$($Case.ErrFirst)/"
    }
    if ($Case.ContainsKey('ErrContains')) {
        foreach ($pattern in @($Case.ErrContains)) {
            if (-not ($errLines -match $pattern)) { $problems += "stderr missing /$pattern/" }
        }
    }

    [pscustomobject]@{ Name = $Case.Name; Ms = $ms; Problems = $problems }
}

"host: $exe ($($PSVersionTable.PSVersion))"
''

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
