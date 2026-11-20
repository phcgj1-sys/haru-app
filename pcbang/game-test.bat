@echo off
rem PC-bang real game test: records FPS (PresentMon), CPU/GPU load, GPU temp and ping while you play.
rem Usage: game-test.bat   or   game-test.bat -Seconds 120 -Seat 23 -Share \\SERVER\pcbang
rem Works from a local folder, a \\SERVER\share path, or a mapped drive (Z:): the admin window cannot see
rem drive letters mapped by the user, so the mapped path is turned into its \\SERVER\share form before elevating.
title PC game test
if not exist "%~dp0game-test.ps1" (echo game-test.ps1 not found. Put game-test.bat and game-test.ps1 in the same folder, and extract ALL files if they came in a zip. & pause & exit /b 1)
fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights for FPS capture...
  set "PCB_SELF=%~f0"
  set "PCB_ARGS=%*"
  powershell -NoProfile -Command "$f=$env:PCB_SELF; try{$r=(Get-PSDrive -Name $f.Substring(0,1) -PSProvider FileSystem -ErrorAction Stop).DisplayRoot; if($r -like '\\*'){$f=$r.TrimEnd('\')+$f.Substring(2)}}catch{}; $p=@{FilePath=$f; Verb='RunAs'; ErrorAction='Stop'}; if($env:PCB_ARGS){$p.ArgumentList=$env:PCB_ARGS}; Start-Process @p" >nul 2>&1
  if not errorlevel 1 exit /b
  echo Admin rights refused: continuing without FPS capture.
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0game-test.ps1" %*
echo.
pause
