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
$requestFilter = Join-Path $prefix 'bin\MoonRequestFilter.dll'
$sample = Join-Path $prefix 'bin\MoonExamplePlugin.exe'
$contractClient = Join-Path $prefix 'bin\MoonPluginContractClient.exe'
$legacyFixture = Join-Path $prefix 'bin\MoonLegacyPluginFixture.exe'
$luaManager = Join-Path $prefix 'bin\MoonLuaManager.exe'
$devTools = Join-Path $prefix 'bin\MoonDevTools.exe'
$history = Join-Path $prefix 'bin\MoonHistory.exe'
$blocker = Join-Path $prefix 'bin\MoonBlocker.exe'
$bookmarks = Join-Path $prefix 'bin\MoonBookmarks.exe'
$downloads = Join-Path $prefix 'bin\MoonDownloads.exe'
$siteData = Join-Path $prefix 'bin\MoonSiteData.exe'
$reading = Join-Path $prefix 'bin\MoonReading.exe'
$appearance = Join-Path $prefix 'bin\MoonAppearance.exe'
$recentTabs = Join-Path $prefix 'bin\MoonRecentTabs.exe'
$session = Join-Path $prefix 'bin\MoonSession.exe'
$tabTools = Join-Path $prefix 'bin\MoonTabTools.exe'
$privateWindow = Join-Path $prefix 'bin\MoonPrivateWindow.exe'
$search = Join-Path $prefix 'bin\MoonSearch.exe'
$privacy = Join-Path $prefix 'bin\MoonPrivacy.exe'
$taskManager = Join-Path $prefix 'bin\MoonTaskManager.exe'
$commandExample = Join-Path $prefix 'bin\MoonCommandExample.exe'
$docs = @(
    $EngineLock
    (Join-Path $repo 'README.md')
    (Join-Path $repo 'THIRD-PARTY.md')
    (Join-Path $repo 'examples\plugin.json')
    (Join-Path $repo 'examples\welcome.user.lua')
    (Join-Path $repo 'examples\lua-manager\plugin.json')
    (Join-Path $repo 'examples\lua-manager\settings.html')
    (Join-Path $repo 'examples\devtools\plugin.json')
    (Join-Path $repo 'examples\page-source\plugin.json')
    (Join-Path $repo 'examples\page-source\source.html')
    (Join-Path $repo 'examples\popups\plugin.json')
    (Join-Path $repo 'examples\popups\popups.html')
    (Join-Path $repo 'examples\history\plugin.json')
    (Join-Path $repo 'examples\history\history.html')
    (Join-Path $repo 'examples\blocker\plugin.json')
    (Join-Path $repo 'examples\blocker\filter.html')
    (Join-Path $repo 'examples\blocker\strict.rules')
    (Join-Path $repo 'examples\bookmarks\plugin.json')
    (Join-Path $repo 'examples\bookmarks\bookmarks.html')
    (Join-Path $repo 'examples\downloads\plugin.json')
    (Join-Path $repo 'examples\downloads\downloads.html')
    (Join-Path $repo 'examples\site-data\plugin.json')
    (Join-Path $repo 'examples\site-data\site-data.html')
    (Join-Path $repo 'examples\reading\plugin.json')
    (Join-Path $repo 'examples\reading\reader.html')
    (Join-Path $repo 'examples\appearance\plugin.json')
    (Join-Path $repo 'examples\appearance\appearance.html')
    (Join-Path $repo 'examples\recent-tabs\plugin.json')
    (Join-Path $repo 'examples\recent-tabs\recent.html')
    (Join-Path $repo 'examples\session\plugin.json')
    (Join-Path $repo 'examples\session\session.html')
    (Join-Path $repo 'examples\tab-tools\plugin.json')
    (Join-Path $repo 'examples\tab-tools\groups.html')
    (Join-Path $repo 'examples\private-window\plugin.json')
    (Join-Path $repo 'examples\search\plugin.json')
    (Join-Path $repo 'examples\search\engines.html')
    (Join-Path $repo 'examples\privacy\plugin.json')
    (Join-Path $repo 'examples\privacy\privacy.html')
    (Join-Path $repo 'examples\task-manager\plugin.json')
    (Join-Path $repo 'examples\task-manager\tasks.html')
    (Join-Path $repo 'examples\ui-commands\plugin.json')
    (Join-Path $repo 'examples\ui-commands\commands.html')
    (Join-Path $repo 'assets\app-icon.ico')
)
if ($Action -eq 'release') {
    $docs += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'distribution') -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
}
$notices = @(Get-ChildItem -LiteralPath (Join-Path $repo 'third_party') -Filter '*.txt' -File | Sort-Object Name)
$pageSource = Join-Path $prefix 'bin\MoonPageSource.exe'
$popups = Join-Path $prefix 'bin\MoonPopups.exe'
$inputHashes = @(($docs + $exe + $requestFilter + $sample + $contractClient + $legacyFixture + $luaManager + $devTools + $pageSource + $popups + $history + $blocker + $bookmarks + $downloads + $siteData + $reading + $appearance + $recentTabs + $session + $tabTools + $privateWindow + $search + $privacy + $taskManager + $commandExample + $notices.FullName) | Get-FileHash -Algorithm SHA256 | Select-Object -ExpandProperty Hash)
$key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((($inputHashes + $engine.sha256) -join ':')))).Substring(0,32).ToLowerInvariant()
$artifact = Join-Path $Root "artifacts\$key"
$stage = Join-Path $work 'artifact'
if (![IO.File]::Exists((Join-Path $artifact 'MoonBrowser.exe'))) {
    $null = [IO.Directory]::CreateDirectory($stage)
    Copy-Item -LiteralPath $exe,$requestFilter -Destination $stage
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
    $manager = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\lua-manager')).FullName
    Copy-Item -LiteralPath $luaManager -Destination $manager
    Copy-Item -LiteralPath (Join-Path $repo 'examples\lua-manager\plugin.json'),(Join-Path $repo 'examples\lua-manager\settings.html') -Destination $manager
    $inspector = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\devtools')).FullName
    Copy-Item -LiteralPath $devTools -Destination $inspector
    Copy-Item -LiteralPath (Join-Path $repo 'examples\devtools\plugin.json') -Destination $inspector
    $sourcePackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\page-source')).FullName
    Copy-Item -LiteralPath $pageSource,(Join-Path $repo 'examples\page-source\plugin.json'),(Join-Path $repo 'examples\page-source\source.html') -Destination $sourcePackage
    $popupPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\popups')).FullName
    Copy-Item -LiteralPath $popups,(Join-Path $repo 'examples\popups\plugin.json'),(Join-Path $repo 'examples\popups\popups.html') -Destination $popupPackage
    $historyPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\history')).FullName
    Copy-Item -LiteralPath $history -Destination $historyPackage
    Copy-Item -LiteralPath (Join-Path $repo 'examples\history\plugin.json'),(Join-Path $repo 'examples\history\history.html') -Destination $historyPackage
    $blockerPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\blocker')).FullName
    Copy-Item -LiteralPath $blocker -Destination $blockerPackage
    Copy-Item -LiteralPath (Join-Path $repo 'examples\blocker\plugin.json'),(Join-Path $repo 'examples\blocker\filter.html'),(Join-Path $repo 'examples\blocker\strict.rules') -Destination $blockerPackage
    $bookmarkPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\bookmarks')).FullName
    Copy-Item -LiteralPath $bookmarks,(Join-Path $repo 'examples\bookmarks\plugin.json'),(Join-Path $repo 'examples\bookmarks\bookmarks.html') -Destination $bookmarkPackage
    $downloadPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\downloads')).FullName
    Copy-Item -LiteralPath $downloads,(Join-Path $repo 'examples\downloads\plugin.json'),(Join-Path $repo 'examples\downloads\downloads.html') -Destination $downloadPackage
    $siteDataPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\site-data')).FullName
    Copy-Item -LiteralPath $siteData,(Join-Path $repo 'examples\site-data\plugin.json'),(Join-Path $repo 'examples\site-data\site-data.html') -Destination $siteDataPackage
    $readingPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\reading')).FullName
    Copy-Item -LiteralPath $reading,(Join-Path $repo 'examples\reading\plugin.json'),(Join-Path $repo 'examples\reading\reader.html') -Destination $readingPackage
    $appearancePackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\appearance')).FullName
    Copy-Item -LiteralPath $appearance,(Join-Path $repo 'examples\appearance\plugin.json'),(Join-Path $repo 'examples\appearance\appearance.html') -Destination $appearancePackage
    $recentPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\recent-tabs')).FullName
    Copy-Item -LiteralPath $recentTabs,(Join-Path $repo 'examples\recent-tabs\plugin.json'),(Join-Path $repo 'examples\recent-tabs\recent.html') -Destination $recentPackage
    $sessionPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\session')).FullName
    Copy-Item -LiteralPath $session,(Join-Path $repo 'examples\session\plugin.json'),(Join-Path $repo 'examples\session\session.html') -Destination $sessionPackage
    $tabToolsPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\tab-tools')).FullName
    Copy-Item -LiteralPath $tabTools,(Join-Path $repo 'examples\tab-tools\plugin.json'),(Join-Path $repo 'examples\tab-tools\groups.html') -Destination $tabToolsPackage
    $privateWindowPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\private-window')).FullName
    Copy-Item -LiteralPath $privateWindow,(Join-Path $repo 'examples\private-window\plugin.json') -Destination $privateWindowPackage
    $searchPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\search')).FullName
    Copy-Item -LiteralPath $search,(Join-Path $repo 'examples\search\plugin.json'),(Join-Path $repo 'examples\search\engines.html') -Destination $searchPackage
    $privacyPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\privacy')).FullName
    Copy-Item -LiteralPath $privacy,(Join-Path $repo 'examples\privacy\plugin.json'),(Join-Path $repo 'examples\privacy\privacy.html') -Destination $privacyPackage
    $taskManagerPackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\task-manager')).FullName
    Copy-Item -LiteralPath $taskManager,(Join-Path $repo 'examples\task-manager\plugin.json'),(Join-Path $repo 'examples\task-manager\tasks.html') -Destination $taskManagerPackage
    $commandExamplePackage = [IO.Directory]::CreateDirectory((Join-Path $stage 'plugins\ui-commands')).FullName
    Copy-Item -LiteralPath $commandExample,(Join-Path $repo 'examples\ui-commands\plugin.json'),(Join-Path $repo 'examples\ui-commands\commands.html') -Destination $commandExamplePackage
    $fixtures = [IO.Directory]::CreateDirectory((Join-Path $stage 'tests')).FullName
    Copy-Item -LiteralPath $contractClient,$legacyFixture -Destination $fixtures
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $artifact))
    [IO.Directory]::Move($stage, $artifact)
}
if ($Action -eq 'release') {
    & (Join-Path $PSScriptRoot 'distribution\build-release.ps1') -Artifact $artifact -Work $work -EngineLock $EngineLock -EngineManifest $contentManifest
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
