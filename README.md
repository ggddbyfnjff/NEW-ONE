# NEW-ONE

## 开机启动拦截开关

一个 Windows 小工具：用开关屏蔽开机时各软件自动发出的启动请求，关闭开关即可原样恢复。

- 安装到桌面：`powershell -ExecutionPolicy Bypass -File startup-guard\install.ps1`，之后双击桌面上的「开机启动拦截」。
- 也可以直接双击 [`startup-guard/StartupGuard.cmd`](startup-guard/StartupGuard.cmd) 打开开关窗口。
- 使用说明、原理和命令行见 [`startup-guard/README.md`](startup-guard/README.md)。
- 不需要管理员权限，不会删除任何启动项或快捷方式。
