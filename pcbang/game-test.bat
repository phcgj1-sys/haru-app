@echo off
rem PC-bang real game test: records FPS (PresentMon), CPU/GPU load, GPU temp and ping while you play.
rem Usage: game-test.bat   or   game-test.bat -Seconds 120 -Seat 23 -Share \\SERVER\pcbang
title PC game test
if not exist "%~dp0game-test.ps1" (echo game-test.ps1 not found. Put game-test.bat and game-test.ps1 in the same folder, and extract ALL files if they came in a zip. & pause & exit /b 1)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights for FPS capture...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
  if not errorlevel 1 exit /b
  echo Admin rights refused: continuing without FPS capture.
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0game-test.ps1" %*
echo.
pause
