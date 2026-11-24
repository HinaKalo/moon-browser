#requires -Version 7.0
param([Parameter(Mandatory)] [string]$AssetDirectory)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path -Parent $PSScriptRoot
$assetDirectory = (Resolve-Path -LiteralPath $AssetDirectory).Path
$appKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BB69CBC1-3A21-4CEA-AA65-0B36D8E14F22}_is1'
if (Test-Path -LiteralPath $appKey) { throw 'Uninstall the existing Moon Browser preview before running this installation test.' }
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
    & python (Join-Path $PSScriptRoot 'smoke.py') (Join-Path $installed 'MoonBrowser.exe') --quick
    Write-Host 'PASS Installer download, Start menu, registration and rendering'
} finally {
    $uninstaller = Join-Path $installed 'unins000.exe'
    if ([IO.File]::Exists($uninstaller)) {
        $remove = Start-Process -FilePath $uninstaller -ArgumentList $silent -WindowStyle Hidden -PassThru -Wait
        if ($remove.ExitCode -or (Test-Path -LiteralPath $appKey) -or
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
