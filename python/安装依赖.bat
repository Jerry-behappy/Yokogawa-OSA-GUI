@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
    python -m venv .venv
    if errorlevel 1 goto failure
)
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto failure
echo.
echo 安装完成。双击“启动Python版.bat”打开程序。
pause
exit /b 0
:failure
echo.
echo 安装失败。请检查 Python 3.10 或以上版本是否已安装并加入 PATH，以及网络连接。
pause
exit /b 1
