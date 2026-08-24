@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "SYSTEM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%SYSTEM_PS%" (
  echo Trusted Windows PowerShell 5.1 was not found.
  pause
  exit /b 70
)
"%SYSTEM_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_DIR%HermesEasySetup.Gui.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo.
  echo Hermes Easy Setup exited with code %EXIT_CODE%.
  pause
)
exit /b %EXIT_CODE%
