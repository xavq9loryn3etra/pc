# Builds Popcorn-Setup-<version>.exe for Windows.
#
# From flutter_client:
#   powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1
# Add -SkipBuild to package the app already in build\windows\x64\runner\Release.
#
# Needs Inno Setup 6 (winget install JRSoftware.InnoSetup) and secrets.json.
# Replaces the earlier homemade installer (windows/build_installer.ps1, removed):
# same folder, same Popcorn.exe, and it takes over its uninstall entry.

param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'

$app = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Push-Location $app
try {
    # Version from pubspec.yaml ("version: 3.0.0+52" -> 3.0.0).
    $line = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*([0-9.]+)' | Select-Object -First 1
    if (-not $line) { throw 'No version: line in pubspec.yaml' }
    $version = $line.Matches[0].Groups[1].Value

    if (-not $SkipBuild) {
        flutter build windows --release --dart-define-from-file=secrets.json
        if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
    }

    $release = 'build\windows\x64\runner\Release'
    if (-not (Test-Path "$release\flutter_client.exe")) { throw "No app build in $release" }

    # A copy of the app with the Microsoft C++ runtime beside it, for PCs
    # without it installed ("VCRUNTIME140_1.dll was not found" on start).
    $stage = 'build\installer\stage'
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item -Recurse "$release\*" $stage
    Move-Item "$stage\flutter_client.exe" "$stage\Popcorn.exe"
    foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
        Copy-Item (Join-Path $env:SystemRoot "System32\$dll") $stage
    }

    $iscc = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 not found: winget install JRSoftware.InnoSetup' }

    & $iscc "/DAppVersion=$version" "/DStageDir=$(Resolve-Path $stage)" 'windows\installer\popcorn.iss'
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
    Remove-Item -Recurse -Force $stage
    Get-Item "build\installer\Popcorn-Setup-$version.exe"
} finally {
    Pop-Location
}
