<#
.SYNOPSIS
Build script for Claude.Agent.Ledger (Invoke-Build).
#>

$started = [datetime]::UtcNow
$ran = [System.Collections.Generic.List[string]]::new()   # tasks that finished in this invocation, for Report
$results = Join-Path $BuildRoot 'artifacts/testResults.xml'

# Synopsis: Run the Pester suite in a clean pwsh.
task Pester {
    exec { pwsh -NoProfile -File "$BuildRoot/tests/Invoke-Tests.ps1" }
    $ran.Add('Pester')
}

# Synopsis: Write artifacts/run-report.json (run-report skill) from this invocation's facts. Pester not run in this
# invocation is a NotRun and the result is not-run, never a stale pass.
task Report {
    Import-Module C:\__Code\Graph\src\Graph\Graph.psd1 -Force
    $facts = @{ Repo = $BuildRoot; Task = "Invoke-Build ($((@($ran) + 'Report') -join ', '))"; StartedAt = $started }
    if ('Pester' -in $ran) {
        $r = ([xml](Get-Content -LiteralPath $results -Raw))['test-results']
        $skipped = [int]$r.skipped + [int]$r.'not-run' + [int]$r.ignored + [int]$r.inconclusive
        $failed = [int]$r.failures + [int]$r.errors
        $facts.BuildResult = 'succeeded'
        $facts.PesterPassed = [int]$r.total - $failed - $skipped
        $facts.PesterFailed = $failed
        $facts.PesterSkipped = $skipped
    }
    else {
        $facts.BuildResult = 'not-run'
        $facts.NotRun = @{ text = 'Pester'; reason = 'not run in this Invoke-Build invocation' }
    }
    $files = New-GraphRunReport @facts
    Write-Build Green "wrote $(@($files).FullName -join ', ')"
}

task . Pester
