param(
    [Parameter(Mandatory)] [string]$Artifact,
    [Parameter(Mandatory)] [string]$Work,
    [Parameter(Mandatory)] [string]$EngineLock,
    [Parameter(Mandatory)] [string]$EngineManifest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$version = Get-Content -LiteralPath (Join-Path $repo 'src\version.json') -Raw | ConvertFrom-Json
$portable = Join-Path $Artifact 'MoonBrowser-Portable-win-x64.zip'
$installer = Join-Path $Artifact 'MoonBrowser-Installer-win-x64.exe'
if ([IO.File]::Exists($portable) -and [IO.File]::Exists($installer)) {
    Write-Output $portable,$installer
    return
}

$engine = Get-Content -LiteralPath $EngineLock -Raw | ConvertFrom-Json
$url = [uri]$engine.url
if (!$url.IsAbsoluteUri -or $url.Scheme -ne 'https' -or $url.AbsoluteUri -match '["{}]' -or
    $engine.archive_bytes -lt 1 -or $engine.archive_bytes -gt 1GB) {
    throw 'Public packaging requires a pinned HTTPS archive and a valid archive_bytes field.'
}
$payload = [IO.Directory]::CreateDirectory((Join-Path $Work 'public-payload')).FullName
foreach ($name in 'MoonBrowser.exe','MoonRequestFilter.dll','README.md','THIRD-PARTY.md','engine.json','licenses','plugins','welcome.user.lua') {
    Copy-Item -LiteralPath (Join-Path $Artifact $name) -Destination $payload -Recurse
}
[IO.File]::WriteAllText((Join-Path $payload 'release-mode'),'installer')

# Identify older, unmarked installations by the verified engine files.
$files = @(Get-Content -LiteralPath $EngineManifest -Raw | ConvertFrom-Json | Sort-Object path)
if (!$files.Count) { throw 'The engine file manifest is empty.' }
$checks = foreach ($file in $files) {
    if ($file.path -notmatch '^[A-Za-z0-9_@. \\-]+$' -or [IO.Path]::IsPathRooted($file.path) -or
        ($file.path -split '\\' | Where-Object { $_ -in '', '.', '..' }) -or $file.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid engine file manifest entry: $($file.path)."
    }
    "  if not EngineFileMatches(Root, '$($file.path)', '$($file.sha256.ToLowerInvariant())') then Exit;"
}
$engineCheck = Join-Path $Work 'engine-check.iss'
(@('function EngineMatches(const Root: String): Boolean;', 'begin', '  Result := False;') +
    $checks + @('  Result := True;', 'end;')) | Set-Content -LiteralPath $engineCheck -Encoding ascii

# Fetch the vendor's portable compiler into the managed build scratch directory.
$compilerSetup = Join-Path $Work 'innosetup-6.7.4.exe'
$compilerRoot = Join-Path $Work 'inno'
$compilerUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe'
$compilerHash = 'a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c'
& curl.exe --fail --location --proto '=https' --proto-redir '=https' --silent --show-error --retry 2 --max-time 300 --max-filesize 10604576 --output $compilerSetup $compilerUrl
if ((Get-FileHash -LiteralPath $compilerSetup -Algorithm SHA256).Hash -ne $compilerHash) {
    throw 'Inno Setup compiler archive SHA-256 mismatch.'
}
$compilerInstall = Start-Process -FilePath $compilerSetup -ArgumentList @('/PORTABLE=1','/CURRENTUSER',
    '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="{0}"' -f $compilerRoot)) -WindowStyle Hidden -PassThru -Wait
if ($compilerInstall.ExitCode) { throw "Portable compiler setup failed (exit $($compilerInstall.ExitCode))." }
$iscc = Join-Path $compilerRoot 'ISCC.exe'
& $iscc ('/DReleaseVersion=' + $version.name) ('/DWindowsVersion=' + $version.windows_version) ('/DPayloadDir=' + $payload) ('/DEngineUrl=' + $url.AbsoluteUri) ("/DAppIcon=" + (Join-Path $repo 'assets\moon-browser.ico')) `
    ('/DEngineHash=' + $engine.sha256) ('/DEngineBytes=' + $engine.archive_bytes) "/DEngineIntegrityInclude=$engineCheck" `
    "/O$Work" (Join-Path $PSScriptRoot 'moon-browser.iss')

foreach ($name in 'Start-MoonBrowser.cmd','Install-Engine.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $payload
}
[IO.File]::WriteAllText((Join-Path $payload 'portable.flag'),'Moon Browser portable profile')
[IO.File]::WriteAllText((Join-Path $payload 'release-mode'),'portable')
$stagedZip = Join-Path $Work 'public-portable.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($payload,$stagedZip,[IO.Compression.CompressionLevel]::Optimal,$false)
[IO.File]::Move($stagedZip,$portable,$true)
[IO.File]::Move((Join-Path $Work 'MoonBrowser-Installer-win-x64.exe'),$installer,$true)
Write-Output $portable,$installer
