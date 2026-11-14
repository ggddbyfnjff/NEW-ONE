@echo off
setlocal
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0StartupGuard.Gui.ps1"
