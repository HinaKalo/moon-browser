#requires -Version 7.0
[CmdletBinding()]
param([switch]$CheckDownload)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'build.ps1'
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = [IO.Path]::GetFullPath((Join-Path $temp ('moon-cache-test-' + [guid]::NewGuid().ToString('N'))))
if (![IO.Path]::GetRelativePath($temp, $sandbox).StartsWith('moon-cache-test-')) {
    throw 'Unsafe test directory.'
}
$cache = Join-Path $sandbox 'cache'
$work = Join-Path $cache 'work'
$outside = Join-Path $sandbox 'outside'
$null = [IO.Directory]::CreateDirectory($work)
$null = [IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $cache '.moon-browser-cache'), 'MoonBrowser build cache v1')
[IO.File]::WriteAllText((Join-Path $work 'engine.zip'), 'abandoned partial archive')
[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
function Assert-Rejected([scriptblock]$Run, [string]$Expected) {
    try { & $Run } catch {
        if ($_.Exception.Message -match $Expected) { return }
        throw
    }
    throw "Expected failure matching $Expected."
}
try {
    & $entry cache-prune -CacheDir $cache -Preview
    if (!(Test-Path -LiteralPath (Join-Path $work 'engine.zip'))) { throw 'Preview modified files.' }
    & $entry cache-prune -CacheDir $cache
    if ([IO.Directory]::Exists($work)) { throw 'Abandoned partial download was retained.' }
    Write-Host 'PASS interrupted-download cleanup and dry run'

    $stream = [IO.File]::Open((Join-Path $cache '.lock'),'Open','ReadWrite','None')
    try {
        Assert-Rejected { & $entry fetch -CacheDir $cache } 'cache is busy'
    } finally { $stream.Dispose() }
    Write-Host 'PASS concurrent owner lock'

    $free = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($cache)).AvailableFreeSpace
    Assert-Rejected { & $entry fetch -CacheDir $cache -FreeFloorBytes ($free+2GB) } 'available bytes'
    if ([IO.Directory]::Exists($work)) { throw 'Low disk space created download files.' }
    Write-Host 'PASS low-space guard'

    foreach ($category in 'engine','artifacts') {
        for ($i=0;$i -lt 4;$i++) {
            $folder = [IO.Directory]::CreateDirectory((Join-Path $cache "$category\generation-$i")).FullName
            [IO.File]::WriteAllText((Join-Path $folder 'fixture.txt'), 'fixture')
            [IO.Directory]::SetLastWriteTimeUtc($folder,[DateTime]::UtcNow.AddMinutes($i-10))
        }
    }
    & $entry cache-prune -CacheDir $cache
    foreach ($category in 'engine','artifacts') {
        $kept = @(Get-ChildItem -LiteralPath (Join-Path $cache $category) -Directory | Sort-Object Name | Select-Object -ExpandProperty Name)
        if (($kept -join ',') -ne 'generation-2,generation-3') { throw "Incorrect retention for $category." }
    }
    Write-Host 'PASS latest-two retention'

    $junction = Join-Path $cache 'engine\escape'
    $null = New-Item -ItemType Junction -Path $junction -Target $outside
    try {
        Assert-Rejected { & $entry cache-prune -CacheDir $cache } 'reparse point'
        if (!(Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))) { throw 'Removed file outside cache.' }
    } finally {
        [IO.Directory]::Delete($junction)
    }
    Write-Host 'PASS junction rejection'

    if ($CheckDownload) {
        $manifest = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'engine.json') -Raw | ConvertFrom-Json
        $manifest.sha256 = '0' * 64
        $lock = Join-Path $sandbox 'bad-engine.json'
        $manifest | ConvertTo-Json | Set-Content -LiteralPath $lock
        Assert-Rejected { & $entry fetch -CacheDir $cache -EngineLock $lock } 'worker failed'
        if ([IO.Directory]::Exists($work) -or [IO.Directory]::Exists((Join-Path $cache "engine\$($manifest.id)-$('0' * 16)"))) {
            throw 'Download hash failure left cache artifacts.'
        }
        Write-Host 'PASS incorrect archive SHA-256 and failed download cleanup'
    }
} finally {
    if ((Get-Item -LiteralPath $sandbox).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected test root junction.' }
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}
