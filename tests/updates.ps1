#requires -Version 7.0
param([Parameter(Mandatory)] [string]$ArtifactDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$version = Get-Content -LiteralPath (Join-Path $repo 'src\version.json') -Raw | ConvertFrom-Json
$assets = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$browser = (Resolve-Path -LiteralPath (Join-Path $assets 'MoonBrowser.exe')).Path
$temp = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
$scratch = [IO.Path]::GetFullPath((Join-Path $temp ('moon-update-test-' + [guid]::NewGuid().ToString('N'))))
$null = [IO.Directory]::CreateDirectory($scratch)
$oldProfile = $env:MOON_BROWSER_PROFILE_DIR
function Probe([string]$Label, [string]$Mode, [long]$Code, [string]$Expected) {
    $profile = [IO.Directory]::CreateDirectory((Join-Path $scratch $Label)).FullName
    $env:MOON_BROWSER_PROFILE_DIR = $profile
    $report = Join-Path $profile 'probe.txt'
    $argsList = @('--relhub-probe',('"{0}"' -f $report),$Mode,"$Code")
    $job = Start-Process -FilePath $browser -ArgumentList $argsList -WindowStyle Hidden -PassThru
    if (!$job.WaitForExit(60000)) {
        $job.Kill()
        throw "Update probe timed out: $Label."
    }
    $line = if (Test-Path -LiteralPath $report) { (Get-Content -LiteralPath $report -Raw).Trim() } else { '' }
    if ($job.ExitCode -ne 0 -or $line -ne $Expected) { throw "Update probe failed: $Label ($line, exit $($job.ExitCode))." }
    Write-Host $line
    $profile
}
try {
    foreach ($mode in 'portable','installer') {
        $name = if ($mode -eq 'portable') { 'MoonBrowser-Portable-win-x64.zip' } else { 'MoonBrowser-Installer-win-x64.exe' }
        $profile = Probe $mode $mode ($version.code - 1) "ready win-x64-$mode $($version.code) $name"
        $download = Join-Path $profile "updates\$name"
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath (Join-Path $assets $name) -Algorithm SHA256).Hash) {
            throw "Browser downloaded different bytes for $mode."
        }
        if (Test-Path -LiteralPath (Join-Path $profile 'updates\update.part')) { throw 'Partial update file was retained.' }
    }
    $current = Probe 'current' 'installer' $version.code 'current win-x64-installer'
    if (Test-Path -LiteralPath (Join-Path $current 'updates')) { throw 'Current version downloaded an update.' }
    Write-Host 'PASS signed public update download for both modes and no-op at current version'
} finally {
    $env:MOON_BROWSER_PROFILE_DIR = $oldProfile
    if (![IO.Path]::GetRelativePath($temp,$scratch).StartsWith('moon-update-test-') -or
        ((Get-Item -LiteralPath $scratch).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unsafe update probe directory.'
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
