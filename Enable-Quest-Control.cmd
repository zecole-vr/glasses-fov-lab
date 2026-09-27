@echo off
chcp 65001 >nul
title Glasses FoV Lab - Enable Quest Controls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\enable-quest-control.ps1"
echo.
pause
