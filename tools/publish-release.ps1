#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ArtifactDirectory,
    [Parameter(Mandatory)] [string]$NotesFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path -Parent $PSScriptRoot
$repo = 'HinaKalo/moon-browser'
$base = 'https://release.moonl.cloud'
$version = Get-Content -LiteralPath (Join-Path $root 'src\version.json') -Raw | ConvertFrom-Json
if ($version.name -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+-preview\.[0-9]+$' -or $version.code -lt 1) {
    throw 'The current release procedure publishes preview versions.'
}
$tag = 'v' + $version.name
$notes = (Resolve-Path -LiteralPath $NotesFile).Path
$artifact = (Resolve-Path -LiteralPath $ArtifactDirectory).Path
$assets = @(
    @{ name = 'MoonBrowser-Portable-win-x64.zip'; platform = 'win-x64-portable' }
    @{ name = 'MoonBrowser-Installer-win-x64.exe'; platform = 'win-x64-installer' }
)
foreach ($item in $assets) {
    $item.path = (Resolve-Path -LiteralPath (Join-Path $artifact $item.name)).Path
    $item.bytes = (Get-Item -LiteralPath $item.path).Length
    $item.url = "$base/v1/apps/moon-browser/$($item.platform)/releases/$($version.code)/download"
}
if ((Get-Item -LiteralPath $assets[1].path).VersionInfo.FileVersion.Trim() -ne $version.windows_version) {
    throw 'Installer file version differs from src/version.json.'
}

function Native([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE)." }
}
function Moon([string]$Command) {
    Native 'ssh' @('-n','-T','-o','BatchMode=yes','-o','ConnectTimeout=10',
        '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','moon',
        "set -eu; export RELHUB_DATA=/var/lib/release-publish; $Command")
}
function Check-Release {
    $release = (Native 'gh' @('release','view',$tag,'--repo',$repo,'--json','isDraft,isPrerelease,targetCommitish,assets,url')) | ConvertFrom-Json
    if (!$release.isPrerelease -or $release.targetCommitish -ne $head) {
        throw 'The existing GitHub Release targets another source revision or channel.'
    }
    foreach ($item in $assets) {
        $uploaded = $release.assets | Where-Object name -EQ $item.name
        if (!$uploaded -or $uploaded.state -ne 'uploaded' -or $uploaded.size -ne $item.bytes) {
            throw "Missing or incomplete GitHub asset: $($item.name)."
        }
    }
    return $release
}

$head = (Native 'git' @('-C',$root,'rev-parse','HEAD')).Trim()
$remoteHead = (Native 'gh' @('api',"repos/$repo/git/ref/heads/main",'--jq','.object.sha')).Trim()
if ($head -ne $remoteHead -or (Native 'git' @('-C',$root,'status','--porcelain'))) {
    throw 'Publish from a clean source commit already pushed to GitHub main.'
}
$lookup = & gh release view $tag --repo $repo --json isDraft,targetCommitish,assets 2>$null
if ($LASTEXITCODE -ne 0) {
    Native 'gh' @('release','create',$tag,$assets[0].path,$assets[1].path,'--repo',$repo,'--draft',
        '--prerelease','--target',$head,'--title',('Moon Browser ' + $version.name),'--notes-file',$notes)
} else {
    $found = $lookup | ConvertFrom-Json
    if ($found.targetCommitish -ne $head) {
        throw 'The release already exists for a different commit.'
    }
    if ($found.isDraft) {
        foreach ($item in $assets) {
            if (!($found.assets | Where-Object name -EQ $item.name)) {
                Native 'gh' @('release','upload',$tag,$item.path,'--repo',$repo)
            }
        }
    }
}
$release = Check-Release

Moon "if ! relhub app show -id moon-browser >/dev/null 2>&1; then relhub app create -id moon-browser -name 'Moon Browser' -desc 'Native Windows browser development previews'; fi"
$pending = @()
foreach ($item in $assets) {
    $response = Invoke-WebRequest -Method Head -Uri $item.url -SkipHttpErrorCheck -TimeoutSec 20
    if ($response.StatusCode -eq 404) { $pending += $item }
    elseif ($response.StatusCode -eq 200) {
        if ([long]($response.Headers['Content-Length'] | Select-Object -First 1) -ne $item.bytes) {
            throw "Unexpected RelHub file size for $($item.name)."
        }
    }
    else { throw "Could not inspect RelHub release at $($item.url). HTTP $($response.StatusCode)." }
}
if ($pending.Count) {
    $stage = (Moon "mktemp -d /tmp/moon-browser-release.XXXXXXXX").Trim()
    if ($stage -cnotmatch '^/tmp/moon-browser-release\.[a-zA-Z0-9]{8}$') { throw 'Unexpected Moon staging directory.' }
    try {
        Native 'scp' @('-q','-o','BatchMode=yes',$notes,"moon:$stage/notes.md")
        foreach ($item in $pending) {
            Native 'scp' @('-q','-o','BatchMode=yes',$item.path,"moon:$stage/$($item.name)")
            Moon "relhub publish -app moon-browser -platform $($item.platform) -no-channel -code $($version.code) -version $($version.name) -file $stage/$($item.name) -name $($item.name) -notes-file $stage/notes.md"
        }
    } finally {
        Moon "rm -f -- $stage/notes.md $stage/$($assets[0].name) $stage/$($assets[1].name); rmdir -- $stage"
    }
}

foreach ($item in $assets) {
    $check = Invoke-RestMethod "$base/v1/apps/moon-browser/check?platform=$($item.platform)&channel=preview&versionCode=0" -TimeoutSec 20 -SkipHttpErrorCheck
    if ($check.PSObject.Properties['manifest'] -and $check.manifest -and $check.manifest.versionCode -gt $version.code) {
        throw "RelHub $($item.platform) preview already points to a newer release."
    }
}
foreach ($item in $assets) {
    Moon "relhub channel promote -app moon-browser -platform $($item.platform) -channel preview -code $($version.code)"
}
if ($release.isDraft) {
    Native 'gh' @('release','edit',$tag,'--repo',$repo,'--draft=false','--prerelease')
}

foreach ($item in $assets) {
    $check = Invoke-RestMethod "$base/v1/apps/moon-browser/check?platform=$($item.platform)&channel=preview&versionCode=0" -TimeoutSec 20
    if ($check.manifest.versionCode -ne $version.code -or $check.manifest.versionName -ne $version.name -or
        $check.manifest.size -ne $item.bytes) {
        throw "The public RelHub preview does not match $($item.name)."
    }
    Write-Output "$($item.name) published on GitHub and Moon ($tag)."
}
