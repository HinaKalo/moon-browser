#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($PSScriptRoot)
$destination = Join-Path $root 'engine'
$work = [IO.Path]::GetFullPath((Join-Path $root '.moon-engine-work'))
$lockPath = Join-Path $root '.moon-engine-lock'
$config = Get-Content -LiteralPath (Join-Path $root 'engine.json') -Raw | ConvertFrom-Json
$remote = [uri]$config.url
if (!$remote.IsAbsoluteUri -or $remote.Scheme -ne 'https' -or
    $config.sha256 -notmatch '^[0-9a-f]{64}$' -or $config.archive_bytes -lt 1 -or $config.archive_bytes -gt 1GB) {
    throw 'Invalid WebKit runtime lock.'
}

function Assert-Plain([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing reparse point $Path"
    }
}
function Assert-Runtime([string]$Path) {
    Assert-Plain $Path
    foreach ($name in 'WebKit2.dll','WebKitWebProcess.exe','WebKitNetworkProcess.exe','WebKit.resources') {
        $entry = Join-Path $Path $name
        Assert-Plain $entry
        if (!(Test-Path -LiteralPath $entry)) { throw "WebKit runtime is missing $name." }
    }
}
function Clear-Work {
    if (!$work.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected WebKit staging path.'
    }
    Assert-Plain $work
    if ([IO.Directory]::Exists($work)) {
        foreach ($entry in Get-ChildItem -LiteralPath $work -Force -Recurse) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing reparse point $($entry.FullName)"
            }
        }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

Assert-Plain $root
Assert-Plain $lockPath
$lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
try {
    Clear-Work
    if (Test-Path -LiteralPath $destination) {
        Assert-Runtime $destination
        $stamp = Join-Path $destination '.moon-engine-sha256'
        Assert-Plain $stamp
        if (!(Test-Path -LiteralPath $stamp) -or ([IO.File]::ReadAllText($stamp)).Trim() -ne $config.sha256) {
            throw 'The existing runtime does not match this release. Extract the new Portable ZIP to a fresh folder.'
        }
        return
    }
    $null = [IO.Directory]::CreateDirectory($work)
    try {
        $archive = Join-Path $work 'webkit.zip'
        $payload = Join-Path $work 'payload'
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        Write-Host 'Downloading and verifying the WebKit runtime from the publisher...'
        & $curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 15 --max-time 600 --max-filesize "$($config.archive_bytes)" --output $archive $remote.AbsoluteUri
        if ($LASTEXITCODE -ne 0) { throw "WebKit download failed (curl exit $LASTEXITCODE)." }
        if ((Get-Item -LiteralPath $archive).Length -ne $config.archive_bytes -or
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $config.sha256) {
            throw 'WebKit download failed its integrity check.'
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($archive,$payload)
        Assert-Runtime $payload
        [IO.File]::WriteAllText((Join-Path $payload '.moon-engine-sha256'),$config.sha256)
        [IO.Directory]::Move($payload,$destination)
    } finally { Clear-Work }
} finally { $lock.Dispose() }
