@echo off
rem PC One-Click Check - GUI launcher (auto-elevates to Administrator)
setlocal
cd /d "%~dp0"
if not exist "%~dp0PCCheck.ps1" (
  echo PCCheck.ps1 not found. Extract the whole ZIP first, then run this file.
  pause
  exit /b 1
)
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  if errorlevel 1 (
    echo Administrator permission was denied. Running with limited access...
    goto run
  )
  exit /b
)
:run
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0PCCheck.ps1" -Mode Gui
exit /b
