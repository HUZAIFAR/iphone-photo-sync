@echo off
title iPhone Photo Sync
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-iPhone.ps1" -UnlockWaitSeconds 60
echo.
pause
