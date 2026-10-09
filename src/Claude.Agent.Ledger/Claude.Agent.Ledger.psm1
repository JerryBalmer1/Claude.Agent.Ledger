Set-StrictMode -Version Latest

foreach ($folder in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path $dir) {
        foreach ($file in Get-ChildItem -Path $dir -Filter '*.ps1' | Sort-Object Name) {
            . $file.FullName
        }
    }
}
