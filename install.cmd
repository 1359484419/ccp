@echo off
rem Double-click to install ccp on Windows. Bypasses execution policy for this run only.
rem install.ps1 has no BOM (so "irm | iex" works); read it explicitly as UTF-8 here so Chinese text is not garbled.
set "CCP_SRC_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:CCP_SRC_DIR + 'install.ps1', [Text.Encoding]::UTF8))"
pause
