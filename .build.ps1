<#
.SYNOPSIS
Build script for Claude.Agent.Ledger (Invoke-Build).
#>

# Synopsis: Run the Pester suite in a clean pwsh.
task Pester {
    exec { pwsh -NoProfile -File "$BuildRoot/tests/Invoke-Tests.ps1" }
}

task . Pester
