@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" "yokogawa_OSA_GUI.py" %*
) else (
    python "yokogawa_OSA_GUI.py" %*
)
set "OSA_EXIT=%ERRORLEVEL%"
if not "%OSA_EXIT%"=="0" (
    echo.
    echo 启动失败，退出码 %OSA_EXIT%。请先运行“安装依赖.bat”。
    echo 错误日志：%%LOCALAPPDATA%%\YokogawaOSAGUI\startup_error.log
    pause
)
exit /b %OSA_EXIT%
