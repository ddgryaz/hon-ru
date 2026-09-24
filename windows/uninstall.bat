@echo off
rem Removes the translation and the shortcut. See windows\README.md
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\uninstall.ps1"
if errorlevel 1 pause
