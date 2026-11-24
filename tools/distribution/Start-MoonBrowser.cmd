@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Install-Engine.ps1"
if errorlevel 1 (
    echo.
    echo Moon Browser could not set up the WebKit runtime.
    pause
    exit /b 1
)
start "" "%~dp0MoonBrowser.exe" %*
