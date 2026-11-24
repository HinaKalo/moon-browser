#requires -Version 5.1
param(
    [Parameter(Mandatory)] [string]$PreviousSetup,
    [Parameter(Mandatory)] [string]$Setup
)
$ErrorActionPreference = 'Stop'
$appKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BB69CBC1-3A21-4CEA-AA65-0B36D8E14F22}_is1'
if (Test-Path -LiteralPath $appKey) { throw 'Run this test in a Windows profile without Moon Browser installed.' }

$PreviousSetup = (Resolve-Path -LiteralPath $PreviousSetup).Path
$Setup = (Resolve-Path -LiteralPath $Setup).Path
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$root = [IO.Directory]::CreateDirectory((Join-Path $temp ('moon-engine-reuse-' + [guid]::NewGuid().ToString('N')))).FullName
$installed = Join-Path $root 'app'
$quiet = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-')
$group = 'Moon Browser Test ' + [IO.Path]::GetFileName($root)

function Run-Setup([string]$File, [string]$Name) {
    $log = Join-Path $root "$Name.log"
    $process = Start-Process -FilePath $File -WindowStyle Hidden -Wait -PassThru -ArgumentList ($quiet + @(
        ('/DIR="{0}"' -f $installed), ('/GROUP="{0}"' -f $group), ('/LOG="{0}"' -f $log)))
    $text = Get-Content -LiteralPath $log -Raw
    if ($process.ExitCode) {
        Get-Content -LiteralPath $log -Tail 30 | Write-Host
        throw "Setup phase $Name failed (exit $($process.ExitCode))."
    }
    return $text
}

try {
    $null = Run-Setup $PreviousSetup 'previous'
    $engine = Join-Path $installed 'engine'
    $library = Join-Path $engine 'brotlicommon.dll'
    if (Test-Path -LiteralPath (Join-Path $engine '.moon-engine-sha256')) {
        throw 'The test must start from an Installer without an engine stamp.'
    }
    $expected = (Get-FileHash -LiteralPath $library).Hash
    $when = (Get-Item -LiteralPath $library).LastWriteTimeUtc
    $upgrade = Run-Setup $Setup 'upgrade'
    if (!$upgrade.Contains('reusing the installed pinned engine; no download.') -or
        $upgrade -match 'cdn\.playwright\.dev' -or (Get-Item -LiteralPath $library).LastWriteTimeUtc -ne $when) {
        throw 'A same-engine upgrade did not take the reuse path.'
    }
    Write-Host 'PASS installer reused unmarked WebKit without downloading'

    [IO.File]::Delete($library)
    $repair = Run-Setup $Setup 'repair'
    if (!$repair.Contains('pinned engine missing or changed; download required.') -or
        $repair -notmatch 'cdn\.playwright\.dev' -or (Get-FileHash -LiteralPath $library).Hash -ne $expected) {
        throw 'The installer did not download and restore a missing engine file.'
    }
    Write-Host 'PASS installer downloaded and repaired missing WebKit'
} finally {
    $uninstaller = Join-Path $installed 'unins000.exe'
    if ([IO.File]::Exists($uninstaller)) {
        $remove = Start-Process -FilePath $uninstaller -ArgumentList $quiet -WindowStyle Hidden -Wait -PassThru
        if ($remove.ExitCode -or (Test-Path -LiteralPath $appKey)) {
            throw 'Test uninstall failed.'
        }
    }
    if ([IO.Path]::GetDirectoryName($root) -ne $temp -or
        ![IO.Path]::GetFileName($root).StartsWith('moon-engine-reuse-') -or
        ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected test directory.'
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
