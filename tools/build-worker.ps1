param(
    [Parameter(Mandatory)] [string]$Action,
    [Parameter(Mandatory)] [string]$Root,
    [Parameter(Mandatory)] [string]$EngineLock,
    [Parameter(Mandatory)] [string]$EngineKey,
    [Parameter(Mandatory)] [long]$HardLimitBytes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path $Root 'work'
$env:TEMP = $work
$env:TMP = $work
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $Root 'zig\local'
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $Root 'zig\global'
$env:ZIG_LOCAL_PKG_DIR = Join-Path $Root 'zig\pkg'

function Invoke-Native([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE) { throw "$Program failed (exit $LASTEXITCODE)." }
}

if ($Action -in 'test','verify') {
    if ((zig version) -ne '0.17.1') { throw 'Zig 0.17.1 is required.' }
    Invoke-Native 'zig' @('build','test','-Doptimize=ReleaseSafe','--summary','all')
    if ($Action -eq 'test') { return }
}

$engine = Get-Content -LiteralPath $EngineLock -Raw | ConvertFrom-Json
$engineHome = Join-Path $Root "engine\$EngineKey"
$runtime = Join-Path $engineHome 'runtime'
$contentManifest = Join-Path $engineHome 'contents.json'
$essential = @('WebKit2.dll','WebKitWebProcess.exe','WebKitNetworkProcess.exe','WebKit.resources')

function Get-RelativeFiles([string]$Directory) {
    Get-ChildItem -LiteralPath $Directory -File -Recurse | ForEach-Object {
        [pscustomobject]@{
            path = [IO.Path]::GetRelativePath($Directory,$_.FullName)
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
}
function Test-Runtime {
    if (![IO.File]::Exists($contentManifest)) { return $false }
    foreach ($file in $essential) {
        if (!(Test-Path -LiteralPath (Join-Path $runtime $file))) { return $false }
    }
    $expected = @((Get-Content -LiteralPath $contentManifest -Raw | ConvertFrom-Json))
    $actual = @(Get-RelativeFiles $runtime)
    return $expected.Count -eq $actual.Count -and !(
        Compare-Object $expected $actual -Property 'path','sha256' -CaseSensitive
    )
}

if (!(Test-Runtime)) {
    $archive = Join-Path $work 'engine.zip'
    $uri = [uri]$engine.url
    if (!$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') { throw 'Engine URL must use HTTPS.' }
    Write-Host "Downloading $($engine.id) ..."
    Invoke-Native 'curl.exe' @('--fail','--location','--proto','=https','--proto-redir','=https',
        '--retry','2','--retry-delay','1','--connect-timeout','15','--max-time','600','--silent','--show-error',
        '--max-filesize',"$HardLimitBytes",'--output',$archive,$uri.AbsoluteUri)
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($digest -ne $engine.sha256) { throw "Unexpected engine SHA-256: $digest" }

    $incoming = Join-Path $work 'engine'
    $unpacked = Join-Path $incoming 'runtime'
    $zipped = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        [long]$unpackedBytes = 0
        foreach ($entry in $zipped.Entries) { $unpackedBytes += $entry.Length }
        if ($unpackedBytes + (Get-Item -LiteralPath $archive).Length -gt $HardLimitBytes) {
            throw 'The unpacked engine will exceed the build-cache budget.'
        }
    } finally { $zipped.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $unpacked)
    foreach ($file in $essential) {
        if (!(Test-Path -LiteralPath (Join-Path $unpacked $file))) { throw "Engine missing $file" }
    }
    Remove-Item -LiteralPath $archive
    @(Get-RelativeFiles $unpacked) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $incoming 'contents.json')
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $engineHome))
    if ([IO.Directory]::Exists($engineHome)) {
        # The cache owner has already checked this tree for reparse points. Move it into
        # the owner-managed work directory before promoting the verified replacement.
        [IO.Directory]::Move($engineHome, (Join-Path $work 'invalid-engine'))
    }
    [IO.Directory]::Move($incoming, $engineHome)
} else {
    Write-Host "Reusing verified runtime $($engine.id)"
}
[IO.Directory]::SetLastWriteTimeUtc($engineHome,[DateTime]::UtcNow)
if ($Action -eq 'fetch') { Write-Output $runtime; return }

if ((zig version) -ne '0.17.1') { throw 'Zig 0.17.1 is required.' }
$prefix = Join-Path $work 'zig-out'
Invoke-Native 'zig' @('build','-Doptimize=ReleaseSafe','--prefix',$prefix)
$exe = Join-Path $prefix 'bin\MoonBrowser.exe'
$sample = Join-Path $prefix 'bin\MoonExamplePlugin.exe'
$contractClient = Join-Path $prefix 'bin\MoonPluginContractClient.exe'
$docs = @(
    $EngineLock
    (Join-Path $repo 'README.md')
    (Join-Path $repo 'THIRD-PARTY.md')
    (Join-Path $repo 'examples\plugin.json')
    (Join-Path $repo 'examples\welcome.user.lua')
)
if ($Action -eq 'release') {
    $docs += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'distribution') -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
}
$notices = @(Get-ChildItem -LiteralPath (Join-Path $repo 'third_party') -Filter '*.txt' -File | Sort-Object Name)
$inputHashes = @(($docs + $exe + $sample + $contractClient + $notices.FullName) | Get-FileHash -Algorithm SHA256 | Select-Object -ExpandProperty Hash)
$key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((($inputHashes + $engine.sha256) -join ':')))).Substring(0,32).ToLowerInvariant()
$artifact = Join-Path $Root "artifacts\$key"
$stage = Join-Path $work 'artifact'
if (![IO.File]::Exists((Join-Path $artifact 'MoonBrowser.exe'))) {
    $null = [IO.Directory]::CreateDirectory($stage)
    Copy-Item -LiteralPath $exe -Destination $stage
    Copy-Item -LiteralPath $runtime -Destination (Join-Path $stage 'engine') -Recurse
    # Playwright.exe is only needed by upstream's test harness.
    $playwright = Join-Path $stage 'engine\Playwright.exe'
    if ([IO.File]::Exists($playwright)) { Remove-Item -LiteralPath $playwright }
    Copy-Item -LiteralPath $EngineLock -Destination (Join-Path $stage 'engine.json')
    Copy-Item -LiteralPath (Join-Path $repo 'THIRD-PARTY.md') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $repo 'README.md') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $repo 'examples\welcome.user.lua') -Destination $stage
    $notice = [IO.Directory]::CreateDirectory((Join-Path $stage 'licenses')).FullName
    $notices | Copy-Item -Destination $notice
    $example = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\example')).FullName
    Copy-Item -LiteralPath $sample -Destination $example
    Copy-Item -LiteralPath (Join-Path $repo 'examples\plugin.json') -Destination $example
    $fixtures = [IO.Directory]::CreateDirectory((Join-Path $stage 'tests')).FullName
    Copy-Item -LiteralPath $contractClient -Destination $fixtures
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $artifact))
    [IO.Directory]::Move($stage, $artifact)
}
if ($Action -eq 'release') {
    & (Join-Path $PSScriptRoot 'distribution\build-release.ps1') -Artifact $artifact -Work $work -EngineLock $EngineLock
} elseif ($Action -in 'package','verify') {
    $package = Join-Path $Root "artifacts\$key\MoonBrowser-win-x64-preview.zip"
    if (![IO.File]::Exists($package)) {
        $stagedZip = Join-Path $work 'preview.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($artifact,$stagedZip,[IO.Compression.CompressionLevel]::Fastest,$false)
        [IO.File]::Move($stagedZip,$package)
    }
    Write-Output $package
} else {
    Write-Output (Join-Path $artifact 'MoonBrowser.exe')
}
[IO.Directory]::SetLastWriteTimeUtc($artifact,[DateTime]::UtcNow)
[IO.File]::WriteAllText((Join-Path $work 'artifact.txt'),$key)
if ($Action -eq 'verify') {
    $report = Join-Path $artifact 'smoke-report.txt'
    Invoke-Native 'python' @('-u',(Join-Path $repo 'tests\smoke.py'),$package,'--ui','--report',$report)
    & (Join-Path $repo 'tests\cache.ps1')
    Write-Output $report
}
