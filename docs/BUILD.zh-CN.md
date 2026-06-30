# 在 VS Code 中编译 Windows 客户端

当前目标只考虑 Windows：

- Go 命令行版：只构建 Windows 64 位
- Flutter GUI 版：只构建 Windows 64 位

## 准备环境

1. 安装 Go 1.22 或更新版本。
2. 使用 VS Code 打开 `GoN2N` 文件夹。
3. 安装 VS Code 的 Go 扩展。
4. 如果要构建 GUI，在 Windows 电脑上安装 Flutter 和 Visual Studio 2022。
5. Visual Studio 需要安装“使用 C++ 的桌面开发”工作负载。

## 编译命令行版 64 位

在 VS Code 终端运行：

```sh
make windows-release
```

结果位于 `dist/`：

```text
gon2n-member-server-windows-x64.exe  Windows 64 位
gon2n-member-server-windows-x86.exe  Windows 32 位
gon2n-member-server-linux-amd64      Linux 64 位
gon2n-member-server-linux-386        Linux 32 位 x86
gon2n-member-server-linux-arm64      Linux ARM64
gon2n-member-server-linux-armv7      Linux ARM 32 位
```

## 编译 Windows GUI

Windows GUI 必须在 Windows 电脑上构建：

```powershell
cd desktop_gui
flutter doctor
flutter build windows --release
```

结果位于：

```text
desktop_gui\build\windows\x64\runner\Release\
```

分发时必须复制整个 `Release` 文件夹，不能只复制其中的 `.exe`。

## 运行要求

Windows 目标电脑还需要：

- 兼容版本的官方 n2n `edge.exe`
- TAP-Windows 驱动
- 管理员权限

GUI 版本会在启动时请求管理员权限。命令行版需要在管理员 PowerShell 中运行。
