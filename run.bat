@echo off
setlocal
title WinDebloat Live (Windows 10 / 11)
cd /d "%~dp0"

set "WDL_PS1=%~dp0WinDebloatLive.ps1"

rem Always 64-bit Windows PowerShell 5.1, also when started from a 32-bit process
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
  echo Windows PowerShell not found. Windows 10 1809 or newer is required.
  echo Khong tim thay Windows PowerShell. Can Windows 10 1809 tro len.
  pause
  exit /b 1
)

rem Elevated instance: started by the block below with this marker as first argument
set "WDL_ARGS=%*"
set "WDL_ELEVATED="
if "%~1"=="__WDL_ELEVATED__" set "WDL_ELEVATED=1"
if defined WDL_ELEVATED set "WDL_ARGS=%WDL_ARGS:*__WDL_ELEVATED__=%"

rem Admin check: fltmc works without the Server service (LanmanServer), unlike "net session".
rem The elevated instance never asks again; the script itself reports missing rights.
if defined WDL_ELEVATED goto :run
"%SystemRoot%\System32\fltmc.exe" >nul 2>&1
if errorlevel 1 goto :elevate

:run
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%WDL_PS1%" %WDL_ARGS%
if errorlevel 1 pause
endlocal
exit /b

:elevate
echo Requesting administrator rights... / Dang xin quyen Administrator...
set "WDL_SELF=%~f0"
rem Elevate cmd.exe with the whole command in an extra pair of quotes, not the .bat itself: the RunAs verb
rem of .bat files loses the quotes when the folder name has brackets or an ampersand, as in a "(1)" download copy.
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "$q = [char]34; $a = '__WDL_ELEVATED__'; if ($env:WDL_ARGS) { $a = $a + ' ' + $env:WDL_ARGS }; Start-Process -FilePath ($env:SystemRoot + '\System32\cmd.exe') -ArgumentList ('/c ' + $q + $q + $env:WDL_SELF + $q + ' ' + $a + $q) -Verb RunAs"
if errorlevel 1 (
  echo Administrator rights were not granted. / Chua duoc cap quyen Administrator.
  pause
)
endlocal
exit /b
