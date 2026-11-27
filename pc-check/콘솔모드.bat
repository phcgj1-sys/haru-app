@echo off
rem PC One-Click Check - console mode (auto-elevates to Administrator)
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  if not errorlevel 1 exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCheck.ps1" -Mode Console
pause
