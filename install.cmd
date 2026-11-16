@echo off
rem Installs the Matrix screensaver on this machine only, for the user who runs it: see install.ps1.
rem Double-click it, or run it with -Remove to undo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
