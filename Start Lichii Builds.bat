@echo off
title Lichii Builds
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0LichiiTray.ps1" -Setup
echo.
timeout /t 10
