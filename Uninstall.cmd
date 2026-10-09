@echo off
cd /d "%TEMP%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
echo.
pause
