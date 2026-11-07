@echo off
title Lichii Checker - status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LichiiChecker.ps1" -Status
echo.
pause
