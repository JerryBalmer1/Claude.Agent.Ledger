@{
    RootModule           = 'Claude.Agent.Ledger.psm1'
    ModuleVersion        = '0.2.1'
    GUID                 = '6f3b1c52-8d0e-4a57-9a43-2f1e7c9b5d10'
    Author               = 'JerryBalmer1'
    Description          = 'Hash-chained, HMAC-authenticated JSONL ledger for Claude.Agent containers.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('New-Ledger', 'Add-LedgerEntry', 'Start-LedgerKeeper', 'Get-Ledger', 'Test-Ledger')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{ PSData = @{ Tags = @('ledger', 'audit', 'hmac') } }
}
