$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$swiftFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'PanPanCamera') -Recurse -Filter '*.swift' |
    ForEach-Object { $_.FullName })
if ($swiftFiles.Count -eq 0) { throw 'No Swift sources found.' }
Get-Command swiftc -ErrorAction Stop | Out-Null
& swiftc -frontend -parse -target arm64-apple-ios17.0 @swiftFiles
if ($LASTEXITCODE -ne 0) { throw 'Swift syntax parsing failed.' }
Write-Output "PASS: parsed $($swiftFiles.Count) Swift source files. This is NOT an Apple SDK typecheck, Xcode build, or XCTest run."
$domainFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'PanPanCamera/Domain') -Filter '*.swift' |
    ForEach-Object { $_.FullName })
if ($domainFiles.Count -eq 0) { throw 'No domain sources found.' }
& swiftc -typecheck -swift-version 5 @domainFiles
if ($LASTEXITCODE -ne 0) { throw 'Pure Swift domain typechecking failed.' }
Write-Output "PASS: typechecked $($domainFiles.Count) pure Swift domain files for the installed host toolchain. No app or test was executed."
