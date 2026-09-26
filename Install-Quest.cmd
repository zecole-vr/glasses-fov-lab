@echo off
chcp 65001 >nul
title Glasses FoV Lab - Quest Installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install-one-click.ps1"
echo.
pause
