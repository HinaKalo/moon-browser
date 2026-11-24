#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('build','test','package','verify','release','cache-status','cache-prune','fetch')] [string]$Action = 'build',
    [string]$CacheDir = '',
    [string]$EngineLock = (Join-Path $PSScriptRoot 'engine.json'),
    [long]$SoftLimitBytes = 3GB,
    [long]$HardLimitBytes = 4GB,
    [long]$FreeFloorBytes = 5GB,
    [switch]$Preview
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (!$CacheDir) { $CacheDir = $env:MOON_BROWSER_CACHE_DIR }
if (!$CacheDir) { $CacheDir = Join-Path $env:LOCALAPPDATA 'MoonBrowser\build-cache' }
$root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($CacheDir))
$driveRoot = [IO.Path]::GetPathRoot($root)
if ($root -eq $driveRoot -or $driveRoot -notmatch '^[A-Za-z]:\\$') {
    throw 'Use a dedicated cache directory on a local drive.'
}
if ($SoftLimitBytes -le 0 -or $HardLimitBytes -le $SoftLimitBytes -or $FreeFloorBytes -lt 0) {
    throw 'Require 0 < soft limit < hard limit and a nonnegative free-space floor.'
}

function Assert-PlainPath([string]$Path) {
    for ($cursor = $Path; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($entry -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing reparse point $cursor"
        }
    }
}
function Get-CacheEntries([string]$Path) {
    if (![IO.Directory]::Exists($Path)) { return }
    try { $entries = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop }
    catch {
        # The worker atomically promotes staging directories while we sample.
        if (![IO.Directory]::Exists($Path)) { return }
        throw
    }
    foreach ($entry in $entries) {
        $attributes = $entry.Attributes
        if ([int]$attributes -eq -1) {
            # FileSystemInfo can return -1 when a staged entry has already moved.
            # Recheck the path so only genuinely missing entries are skipped.
            try { $attributes = [IO.File]::GetAttributes($entry.FullName) }
            catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { continue }
        }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse point $($entry.FullName)"
        }
        $entry
        if ($entry.PSIsContainer) { Get-CacheEntries $entry.FullName }
    }
}
function Get-CacheSize([string]$Path) {
    [long]$total = 0
    foreach ($entry in Get-CacheEntries $Path) {
        if (!$entry.PSIsContainer) {
            try { $total += $entry.Length }
            catch {
                if ([IO.File]::Exists($entry.FullName)) { throw }
            }
        }
    }
    $total
}
function Remove-CacheEntry([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if (!$absolute.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside the cache: $absolute"
    }
    Assert-PlainPath $absolute
    if (![IO.Directory]::Exists($absolute) -and ![IO.File]::Exists($absolute)) { return $true }
    $null = @(Get-CacheEntries $absolute)
    if ($Preview) {
        Write-Host "Would remove $absolute"
        return $true
    }
    try {
        Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Could not remove $absolute ($($_.Exception.Message)). Close any running build or browser using it."
        return $false
    }
}
function Get-FreeBytes {
    ([IO.DriveInfo]::new($driveRoot)).AvailableFreeSpace
}
function Get-Generations([string]$Category) {
    Get-ChildItem -LiteralPath (Join-Path $root $Category) -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
}
function Prune-Cache([string]$KeepEngine = '', [string]$KeepArtifact = '') {
    $remaining = Get-CacheSize $root
    $wouldFree = 0L
    foreach ($category in 'engine','artifacts') {
        $keep = if ($category -eq 'engine') { $KeepEngine } else { $KeepArtifact }
        $generations = @(Get-Generations $category)
        $preferred = @($generations | Where-Object Name -EQ $keep) +
            @($generations | Where-Object Name -NE $keep)
        foreach ($generation in ($preferred | Select-Object -Skip 2)) {
            $size = Get-CacheSize $generation.FullName
            if (Remove-CacheEntry $generation.FullName) { $remaining -= $size; $wouldFree += $size }
        }
    }
    $candidates = @(
        Get-Generations 'engine' | Where-Object Name -NE $KeepEngine
        Get-Generations 'artifacts' | Where-Object Name -NE $KeepArtifact
    ) | Sort-Object LastWriteTimeUtc
    $candidates = @($candidates) + @(Get-Item -LiteralPath (Join-Path $root 'zig') -ErrorAction SilentlyContinue)
    foreach ($candidate in $candidates) {
        $free = (Get-FreeBytes) + $(if ($Preview) { $wouldFree } else { 0 })
        if ($remaining -le $SoftLimitBytes -and $free -ge $FreeFloorBytes) { break }
        if (![IO.Directory]::Exists($candidate.FullName)) { continue }
        $size = Get-CacheSize $candidate.FullName
        if (Remove-CacheEntry $candidate.FullName) { $remaining -= $size; $wouldFree += $size }
    }
    if ($remaining -gt $HardLimitBytes -or (Get-FreeBytes) + $(if ($Preview) { $wouldFree } else { 0 }) -lt $FreeFloorBytes) {
        throw "Build cache exceeds its budget or the disk has less than $FreeFloorBytes available bytes."
    }
}

Assert-PlainPath $root
if ([IO.Directory]::Exists($root) -and ![IO.File]::Exists((Join-Path $root '.moon-browser-cache'))) {
    if (@(Get-ChildItem -LiteralPath $root -Force).Count) {
        throw "Cache directory already contains unrelated files: $root"
    }
}
if (![IO.Directory]::Exists($root) -and $Action -in 'cache-status','cache-prune') {
    Write-Host "Empty cache: $root"
    return
}
$null = [IO.Directory]::CreateDirectory($root)
$marker = Join-Path $root '.moon-browser-cache'
$lockPath = Join-Path $root '.lock'
Assert-PlainPath $marker
Assert-PlainPath $lockPath
try {
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch [IO.IOException] {
    throw "The MoonBrowser cache is busy: $root"
}
try {
    if (![IO.File]::Exists($marker)) { [IO.File]::WriteAllText($marker, 'MoonBrowser build cache v1') }
    if ($Action -eq 'cache-status') {
        [pscustomobject]@{ Cache = $root; Bytes = (Get-CacheSize $root); FreeBytes = (Get-FreeBytes); SoftBytes = $SoftLimitBytes; HardBytes = $HardLimitBytes } | Format-List
        Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
            [pscustomobject]@{ Category = $_.Name; Bytes = (Get-CacheSize $_.FullName) }
        } | Format-Table -AutoSize
        return
    }
    $scratch = Join-Path $root 'work'
    if (!(Remove-CacheEntry $scratch)) { throw "Cannot clear previous work directory $scratch." }
    if ($Action -eq 'cache-prune') {
        Prune-Cache
        return
    }
    if ($Preview) { throw '-Preview is only for cache-prune.' }

    $EngineLock = (Resolve-Path -LiteralPath $EngineLock).Path
    $engine = Get-Content -LiteralPath $EngineLock -Raw | ConvertFrom-Json
    if ($engine.id -cnotmatch '^[a-z0-9][a-z0-9-]{1,80}$' -or $engine.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $engine.revision -notmatch '^[0-9a-f]{40}$' -or $engine.backend -cnotin 'Skia','Cairo') {
        throw 'Invalid engine lock.'
    }
    $engineKey = "$($engine.id)-$($engine.sha256.Substring(0,16).ToLowerInvariant())"
    Prune-Cache $engineKey
    $null = [IO.Directory]::CreateDirectory($scratch)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = $PSScriptRoot
    foreach ($argument in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'tools\build-worker.ps1'),
        '-Action',$Action,'-Root',$root,'-EngineLock',$EngineLock,'-EngineKey',$engineKey,
        '-HardLimitBytes',"$HardLimitBytes")) { $start.ArgumentList.Add($argument) }
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $worker = $null
    try {
        $worker = [Diagnostics.Process]::Start($start)
        $stdout = $worker.StandardOutput.ReadToEndAsync()
        $stderr = $worker.StandardError.ReadToEndAsync()
        do {
            $done = $worker.WaitForExit(500)
            if ((Get-CacheSize $root) -gt $HardLimitBytes -or (Get-FreeBytes) -lt $FreeFloorBytes) {
                throw 'Build stopped because the cache or free-space budget was exceeded.'
            }
        } until ($done)
        if ($stdout.Result) { Write-Host $stdout.Result.TrimEnd() }
        if ($stderr.Result) { Write-Host $stderr.Result.TrimEnd() }
        if ($worker.ExitCode) { throw "Build worker failed (exit $($worker.ExitCode))." }
    } finally {
        if ($worker) {
            if (!$worker.HasExited) {
                try { $worker.Kill($true) } catch [InvalidOperationException] {}
                $worker.WaitForExit()
            }
            $worker.Dispose()
        }
        $keepArtifact = ''
        $result = Join-Path $scratch 'artifact.txt'
        if ([IO.File]::Exists($result)) { $keepArtifact = [IO.File]::ReadAllText($result).Trim() }
        $null = Remove-CacheEntry $scratch
        Prune-Cache $engineKey $keepArtifact
    }
} finally {
    $lock.Dispose()
}
