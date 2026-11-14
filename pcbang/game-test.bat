@echo off
rem PC-bang real game test: records FPS (PresentMon), CPU/GPU load, GPU temp and ping while you play.
rem Usage: game-test.bat   or   game-test.bat -Seconds 120 -Seat 23 -Share \\SERVER\pcbang
rem Run it from a local folder or a \\SERVER\share path (not a mapped drive letter like Z:).
title PC game test
if not exist "%~dp0game-test.ps1" (echo game-test.ps1 not found. Put game-test.bat and game-test.ps1 in the same folder, and extract ALL files if they came in a zip. & pause & exit /b 1)
fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights for FPS capture...
  set "PCB_SELF=%~f0"
  set "PCB_ARGS=%*"
  powershell -NoProfile -Command "$p=@{FilePath=$env:PCB_SELF; Verb='RunAs'; ErrorAction='Stop'}; if($env:PCB_ARGS){$p.ArgumentList=$env:PCB_ARGS}; Start-Process @p" >nul 2>&1
  if not errorlevel 1 exit /b
  echo Admin rights refused: continuing without FPS capture.
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0game-test.ps1" %*
echo.
pause
