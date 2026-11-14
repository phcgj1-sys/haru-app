@echo off
rem PC-bang game check - runs pc-check.ps1 next to this file (no install, no admin needed)
title PC check
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc-check.ps1"
echo.
pause
