@echo off
chcp 65001 >nul
setlocal EnableExtensions
cd /d "%~dp0"
title 本地聊天工具

where node >nul 2>nul
if errorlevel 1 (
  echo [错误] 未找到 Node.js。
  echo 请先从 https://nodejs.org/ 安装 Node.js 18 或更高版本，然后重新双击本文件。
  pause
  exit /b 1
)

node -e "process.exit(Number(process.versions.node.split('.')[0]) >= 18 ? 0 : 1)" >nul 2>nul
if errorlevel 1 (
  echo [错误] Node.js 版本过低，需要 18 或更高版本。当前版本：
  node --version
  pause
  exit /b 1
)

if not defined GITHUB_TOKEN if not defined CHAT_GITHUB_TOKEN if not defined CHAT_TOKEN_FILE if not exist "%~dp0token.txt" (
  echo [提示] 尚未配置 GitHub 访问令牌。
  echo.
  echo 请将令牌写入：%~dp0token.txt
  echo 文件内只放一行令牌；也可以设置环境变量 GITHUB_TOKEN。
  echo 详细步骤见 README.md。
  pause
  exit /b 1
)

echo 正在启动本地聊天工具...
node "%~dp0server.js" --open
set "exit_code=%errorlevel%"

if not "%exit_code%"=="0" (
  echo.
  echo 服务退出，代码 %exit_code%。请查看上面的错误信息。
  pause
)

endlocal
