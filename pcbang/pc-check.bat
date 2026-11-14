@echo off
rem PC-bang game check - runs pc-check.ps1 next to this file (no install, no admin needed)
title PC check
if not exist "%~dp0pc-check.ps1" (echo pc-check.ps1 not found. Put pc-check.bat and pc-check.ps1 in the same folder, and extract ALL files if they came in a zip. & pause & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-check.ps1"
echo.
pause
