@echo off
rem Double-click: builds and installs Muna (needs the .NET 10 SDK).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
