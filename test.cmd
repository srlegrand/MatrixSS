@echo off
rem Starts the screensaver on every machine at once: see test.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test.ps1" %*
