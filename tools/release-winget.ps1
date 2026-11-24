#requires -Version 7.0
param(
    [Parameter(Mandatory)] [pscustomobject]$Version,
    [Parameter(Mandatory)] [string]$Installer,
    [Parameter(Mandatory)] [string]$ManifestDirectory,
    [switch]$Submit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$id = 'HinaKalo.MoonBrowser'
$upstream = 'microsoft/winget-pkgs'
$fork = 'HinaKalo/winget-pkgs'
$prefix = 'manifests/h/HinaKalo/MoonBrowser/'
$name = $Version.name
$code = $Version.code

if (!$Submit) {
    $null = [IO.Directory]::CreateDirectory($ManifestDirectory)
    $installerHash = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash
    $manifests = @{
        "$id.yaml" = @"
# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.28.0.schema.json
PackageIdentifier: $id
PackageVersion: $name
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.28.0
"@
        "$id.installer.yaml" = @"
# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.28.0.schema.json
PackageIdentifier: $id
PackageVersion: $name
InstallerType: inno
Scope: user
Installers:
- Architecture: x64
  InstallerUrl: https://release.moonl.cloud/v1/apps/moon-browser/win-x64-installer/releases/$code/download
  InstallerSha256: $installerHash
  ProductCode: '{BB69CBC1-3A21-4CEA-AA65-0B36D8E14F22}_is1'
ManifestType: installer
ManifestVersion: 1.28.0
"@
        "$id.locale.en-US.yaml" = @"
# yaml-language-server: $schema=https://aka.ms/winget-manifest.defaultLocale.1.28.0.schema.json
PackageIdentifier: $id
PackageVersion: $name
PackageLocale: en-US
Publisher: HinaKalo
PublisherUrl: https://github.com/HinaKalo
PublisherSupportUrl: https://github.com/HinaKalo/moon-browser/issues
PackageName: Moon Browser Preview
PackageUrl: https://github.com/HinaKalo/moon-browser
License: Proprietary
Copyright: Copyright HinaKalo
ShortDescription: A native Windows browser development preview built with Zig and WebKit.
ReleaseNotesUrl: https://github.com/HinaKalo/moon-browser/releases/tag/v$name
ManifestType: defaultLocale
ManifestVersion: 1.28.0
"@
    }
    foreach ($file in $manifests.Keys) {
        Set-Content -LiteralPath (Join-Path $ManifestDirectory $file) -Value $manifests[$file] -Encoding utf8
    }
    winget validate --manifest $ManifestDirectory --disable-interactivity
    return
}

function GitHub([string]$Method, [string]$Path, [hashtable]$Body) {
    $Body | ConvertTo-Json -Depth 8 -Compress | gh api --method $Method $Path --input - | ConvertFrom-Json
}

$prs = @(gh pr list --repo $upstream --state open --author HinaKalo --search "$id in:title" --json number,headRefName,headRepositoryOwner,title |
    ConvertFrom-Json | Where-Object { $_.headRepositoryOwner.login -eq 'HinaKalo' -and $_.headRefName -match '^codex/moon-browser-preview-\d+$' })
if ($prs.Count -gt 1) { throw 'Multiple Moon Browser WinGet submissions are open.' }
$pr = $prs | Select-Object -First 1
$branch = if ($pr) { $pr.headRefName } else { "codex/moon-browser-preview-$code" }
$oldFiles = @(if ($pr) { gh api "repos/$upstream/pulls/$($pr.number)/files" --paginate --jq '.[].filename' })
$tree = @()
foreach ($path in $oldFiles) {
    if (!$path.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "Unrelated WinGet change on $branch." }
    if (!$path.StartsWith("$prefix$name/", [StringComparison]::Ordinal)) {
        $tree += @{ path = $path; mode = '100644'; type = 'blob'; sha = $null }
    }
}
$title = if ($pr -and $pr.title.StartsWith('New package:')) { "New package: $id version $name" } else { "$id version $name" }
$files = @(Get-ChildItem -LiteralPath $ManifestDirectory -Filter '*.yaml' -File)
if ($files.Count -ne 3) { throw 'Expected three WinGet manifests.' }
$paths = @($files | ForEach-Object { "$prefix$name/$($_.Name)" })
if ($pr -and $oldFiles.Count -eq 3 -and !($paths | Where-Object { $_ -notin $oldFiles })) {
    if ($pr.title -ne $title) { $null = GitHub PATCH "repos/$upstream/pulls/$($pr.number)" @{ title = $title } }
    Write-Output "WinGet submission: https://github.com/$upstream/pull/$($pr.number)"
    return
}
$ref = if ($pr) { $branch } else { 'master' }
if (!$pr) {
    $null = gh api --method POST "repos/$fork/merge-upstream" -f branch=master
}
$parent = (gh api "repos/$fork/git/ref/heads/$ref" --jq '.object.sha').Trim()
$baseTree = (gh api "repos/$fork/git/commits/$parent" --jq '.tree.sha').Trim()
foreach ($file in $files) {
    $blob = GitHub POST "repos/$fork/git/blobs" @{
        encoding = 'base64'; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
    }
    $tree += @{ path = "$prefix$name/$($file.Name)"; mode = '100644'; type = 'blob'; sha = $blob.sha }
}
$updated = GitHub POST "repos/$fork/git/trees" @{ base_tree = $baseTree; tree = $tree }
$commit = GitHub POST "repos/$fork/git/commits" @{ message = $title; tree = $updated.sha; parents = @($parent) }
if ($pr) {
    $null = GitHub PATCH "repos/$fork/git/refs/heads/$branch" @{ sha = $commit.sha; force = $false }
    $null = GitHub PATCH "repos/$upstream/pulls/$($pr.number)" @{ title = $title }
    Write-Output "WinGet submission: https://github.com/$upstream/pull/$($pr.number)"
} else {
    $null = GitHub POST "repos/$fork/git/refs" @{ ref = "refs/heads/$branch"; sha = $commit.sha }
    gh pr create --repo $upstream --base master --head "HinaKalo:$branch" --title $title --body "Moon Browser preview $name from release.moonl.cloud."
}
