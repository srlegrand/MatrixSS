@echo off
rem Installs the Matrix screensaver on this machine and the others: see deploy.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
