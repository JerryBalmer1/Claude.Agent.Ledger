#Requires -Version 7.4
# Run with: pwsh -NoProfile -File tests/Invoke-Tests.ps1
# Writes artifacts/testResults.xml (NUnit) for the Report task.
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot '../artifacts/testResults.xml'
Invoke-Pester -Configuration $config
