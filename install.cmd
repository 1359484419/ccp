@echo off
rem Double-click to install ccp on Windows. Bypasses execution policy for this run only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
