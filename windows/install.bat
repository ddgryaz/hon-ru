@echo off
rem Installs the "HoN (RU)" desktop shortcut. See windows\README.md
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\install.ps1"
if errorlevel 1 pause
