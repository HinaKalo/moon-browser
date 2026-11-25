#requires -Version 7.0
[CmdletBinding()]
param([switch]$Async, [string]$Commit)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path -Parent $PSScriptRoot
$jobs = Join-Path $env:LOCALAPPDATA 'MoonBrowser\release-jobs'
if (!$Commit) {
    if (git -C $root status --porcelain) { throw 'Commit your release changes before starting.' }
    $Commit = (git -C $root rev-parse HEAD).Trim()
}
if ($Commit -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid release commit.' }
$version = git -C $root show "$($Commit):src/version.json" | ConvertFrom-Json
if ($version.name -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+$') { throw 'Expected a preview version.' }
$null = [IO.Directory]::CreateDirectory($jobs)
$log = Join-Path $jobs "$($version.name).log"

if ($Async) {
    $worker = Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden -WorkingDirectory $root -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', ('"{0}"' -f $PSCommandPath), '-Commit', $Commit
    )
    Write-Output "Release $($version.name) started (PID $($worker.Id)). Log: $log"
    return
}

$checkout = Join-Path $jobs ("source-" + [guid]::NewGuid().ToString('N'))
$attached = $false
$started = $false
$lock = $null
try {
    $null = Start-Transcript -Path $log -Append
    $started = $true
    $lock = [IO.File]::Open((Join-Path $jobs 'publish.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    Get-ChildItem -LiteralPath $jobs -Filter '*.log' -File |
        Where-Object FullName -NE $log | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 4 |
        Remove-Item
    Write-Host "RELEASE $($version.name)  $Commit"
    git -C $root worktree add --detach $checkout $Commit
    $attached = $true
    Push-Location -LiteralPath $checkout
    $artifactLease = $null
    try {
        & .\build.ps1 test
        $lines = @(& .\build.ps1 release -ArtifactLease ([ref]$artifactLease) 6>&1 | ForEach-Object { Write-Host "$_"; "$_" }) -split '\r?\n'
        if (!$artifactLease) { throw 'Build did not lease its release artifact.' }
        $portable = $lines | Where-Object { [IO.Path]::IsPathFullyQualified($_) -and $_.EndsWith('\MoonBrowser-Portable-win-x64.zip') } | Select-Object -Last 1
        if (!$portable -or ![IO.File]::Exists($portable)) { throw 'Build returned no Portable archive.' }
        $artifact = Split-Path -Parent $portable
        $installer = Join-Path $artifact 'MoonBrowser-Installer-win-x64.exe'
        if (![IO.File]::Exists($installer) -or (Get-Item -LiteralPath $installer).VersionInfo.FileVersion.Trim() -ne $version.windows_version) {
            throw 'Installer output is missing or has the wrong version.'
        }
        $package = [IO.Compression.ZipFile]::OpenRead($portable)
        try {
            foreach ($name in 'MoonBrowser.exe','portable.flag','Install-Engine.ps1','welcome.user.lua') {
                if (!$package.GetEntry($name)) { throw "Portable package is missing $name." }
            }
        } finally { $package.Dispose() }
        try {
            python -u .\tests\smoke.py (Join-Path $artifact 'MoonBrowser.exe') --quick --ui
        } catch {
            if ($LASTEXITCODE -ne 75) { throw }
            Write-Warning 'WebKit terminated before the intentional crash test. Retrying once with a fresh test profile.'
            python -u .\tests\smoke.py (Join-Path $artifact 'MoonBrowser.exe') --quick --ui
        }

        $manifests = Join-Path $checkout "out\winget\$($version.name)"
        & .\tools\release-winget.ps1 -Version $version -Installer $installer -ManifestDirectory $manifests
        git push origin "$($Commit):refs/heads/main"
        & .\tools\publish-release.ps1 -ArtifactDirectory $artifact -NotesFile ".\docs\$($version.name).md"
        & .\tools\release-winget.ps1 -Version $version -Installer $installer -ManifestDirectory $manifests -Submit
    } finally {
        if ($artifactLease) { $artifactLease.Dispose() }
        Pop-Location
    }
    git -C $root worktree remove $checkout --force
    $attached = $false
    Write-Host "RELEASE COMPLETE $($version.name)"
} catch {
    Write-Host "RELEASE FAILED $($version.name): $_"
    throw
} finally {
    try {
        if ($attached) { git -C $root worktree remove $checkout --force }
    } finally {
        if ($started) { $null = Stop-Transcript }
        if ($lock) { $lock.Dispose() }
    }
}
