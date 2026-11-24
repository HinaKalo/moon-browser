#requires -Version 7.0
param([Parameter(Mandatory)] [string]$AssetDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path -Parent $PSScriptRoot
$assetDirectory = (Resolve-Path -LiteralPath $AssetDirectory).Path
$appKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BB69CBC1-3A21-4CEA-AA65-0B36D8E14F22}_is1'
if (Test-Path -LiteralPath $appKey) { throw 'Uninstall the existing Moon Browser preview before running this installation test.' }
$registeredApps = 'HKCU:\Software\RegisteredApplications'
$browserKey = 'HKCU:\Software\Clients\StartMenuInternet\MoonBrowser'
$protocolKey = 'HKCU:\Software\Classes\MoonBrowser.URL'
function MoonBrowserRegistration {
    $registry = Get-Item -LiteralPath $registeredApps -ErrorAction SilentlyContinue
    if ($registry) { $registry.GetValue('Moon Browser') }
}
if ((MoonBrowserRegistration) -or
    (Test-Path -LiteralPath $browserKey) -or (Test-Path -LiteralPath $protocolKey)) {
    throw 'A pre-existing Moon Browser protocol registration is present.'
}

function DefaultLinkChoices {
    foreach ($scheme in 'http','https') {
        $choice = "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$scheme\UserChoice"
        $registry = Get-Item -LiteralPath $choice -ErrorAction SilentlyContinue
        if ($registry) { "${scheme}:$($registry.GetValue('ProgId'))" }
    }
}
$originalChoices = @(DefaultLinkChoices) -join "`n"
$temp = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))
$root = [IO.Path]::GetFullPath((Join-Path $temp ('moon-distribution-' + [guid]::NewGuid().ToString('N').Substring(0,12))))
$null = [IO.Directory]::CreateDirectory($root)
$portable = Join-Path $root 'portable'
$installed = Join-Path $root 'installed'
$group = 'Moon Browser Test ' + [IO.Path]::GetFileName($root)
$silent = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-')
$shortcut = $null
try {
    $zip = Join-Path $assetDirectory 'MoonBrowser-Portable-win-x64.zip'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip,$portable)
    if ((Test-Path -LiteralPath (Join-Path $portable 'engine')) -or
        !(Test-Path -LiteralPath (Join-Path $portable 'portable.flag'))) { throw 'Portable archive is laid out incorrectly.' }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $portable 'Install-Engine.ps1')
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $portable 'Install-Engine.ps1')
    & python (Join-Path $PSScriptRoot 'smoke.py') (Join-Path $portable 'MoonBrowser.exe') --quick
    Write-Host 'PASS Portable bootstrap, reuse and rendering'

    $setup = Join-Path $assetDirectory 'MoonBrowser-Installer-win-x64.exe'
    $log = Join-Path $root 'installer.log'
    $download = Start-Process -FilePath $setup -ArgumentList ($silent + @(
        ('/DIR="{0}"' -f $installed),('/GROUP="{0}"' -f $group),('/LOG="{0}"' -f $log))) -WindowStyle Hidden -PassThru -Wait
    if ($download.ExitCode) {
        if ([IO.File]::Exists($log)) { Get-Content -LiteralPath $log -Tail 35 | Write-Host }
        throw "Installer returned $($download.ExitCode)."
    }
    $programs = [Environment]::GetFolderPath('Programs')
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = Get-ChildItem -LiteralPath $programs -Recurse -Filter 'Moon Browser.lnk' -File |
        Where-Object { $shell.CreateShortcut($_.FullName).TargetPath -eq (Join-Path $installed 'MoonBrowser.exe') } |
        Select-Object -First 1 -ExpandProperty FullName
    $registered = Test-Path -LiteralPath $appKey
    if (!$registered -or !$shortcut -or (Test-Path -LiteralPath (Join-Path $installed 'portable.flag'))) {
        Get-Content -LiteralPath $log -Tail 45 | Write-Host
        throw "Incorrect installer registration (uninstall entry=$registered, shortcut=$shortcut)."
    }
    $expectedHandler = '"{0}" --open-url "%1"' -f (Join-Path $installed 'MoonBrowser.exe')
    $actualHandler = (Get-Item -LiteralPath "$protocolKey\shell\open\command").GetValue('')
    if ((MoonBrowserRegistration) -cne 'Software\Clients\StartMenuInternet\MoonBrowser\Capabilities' -or
        (Get-ItemPropertyValue -LiteralPath "$browserKey\Capabilities\URLAssociations" -Name http) -cne 'MoonBrowser.URL' -or
        (Get-ItemPropertyValue -LiteralPath "$browserKey\Capabilities\URLAssociations" -Name https) -cne 'MoonBrowser.URL' -or
        $actualHandler -cne $expectedHandler -or (@(DefaultLinkChoices) -join "`n") -cne $originalChoices) {
        throw 'The browser registration is incomplete or changed the selected Windows defaults.'
    }
    & python (Join-Path $PSScriptRoot 'smoke.py') (Join-Path $installed 'MoonBrowser.exe') --quick
    Write-Host 'PASS Installer download, Start menu, HTTP/HTTPS registration and rendering'
} finally {
    $uninstaller = Join-Path $installed 'unins000.exe'
    if ([IO.File]::Exists($uninstaller)) {
        $remove = Start-Process -FilePath $uninstaller -ArgumentList $silent -WindowStyle Hidden -PassThru -Wait
        if ($remove.ExitCode -or (Test-Path -LiteralPath $appKey) -or
            (Test-Path -LiteralPath $browserKey) -or (Test-Path -LiteralPath $protocolKey) -or
            (MoonBrowserRegistration) -or
            (@(DefaultLinkChoices) -join "`n") -cne $originalChoices -or
            (Test-Path -LiteralPath (Join-Path $installed 'engine\WebKit2.dll')) -or
            ($shortcut -and (Test-Path -LiteralPath $shortcut))) {
            throw 'Installer cleanup did not remove the installation.'
        }
        Write-Host 'PASS Installer uninstall'
    }
    if (![IO.Path]::GetRelativePath($temp,$root).StartsWith('moon-distribution-') -or
        ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected distribution test directory.'
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
