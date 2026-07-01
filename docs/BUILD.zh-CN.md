# 构建 GoN2N

GoN2N 当前包含三个主要构建目标：

- member-server：由 Go 构建，可交叉编译 Windows、Linux、x86、x64、ARM64、ARMv7
- n2nR-server：由 n2n supernode 源码加 GoN2N patch 构建，可构建 Linux / Windows 多架构
- Windows GUI：由 Flutter 构建，目前发布 Windows x64 客户端

## 准备环境

1. 安装 Go 1.22 或更新版本。
2. 使用 VS Code 打开 `GoN2N` 文件夹。
3. 安装 VS Code 的 Go 扩展。
4. 如果要构建 GUI，在 Windows 电脑上安装 Flutter 和 Visual Studio 2022。
5. Visual Studio 需要安装“使用 C++ 的桌面开发”工作负载。
6. 如果要在 Linux 服务器上一键构建 n2nR 多架构版本，需要安装对应交叉编译工具链。

## 构建 member-server

在项目根目录运行：

```sh
sh scripts/build-release.sh
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

也可以通过 Makefile 调用：

```sh
make release
```

## 构建 n2nR-server

默认构建 Linux amd64：

```sh
sh scripts/build-n2nr-linux-amd64.sh
```

一键构建当前支持的 6 个 n2nR-server 目标：

```sh
TARGET=all sh scripts/build-n2nr-linux-amd64.sh
```

结果位于 `dist/`：

```text
n2nR-server-linux-amd64
n2nR-server-linux-386
n2nR-server-linux-arm64
n2nR-server-linux-armv7
n2nR-server-windows-x64.exe
n2nR-server-windows-x86.exe
```

如果构建 Windows 目标，需要安装 MinGW 交叉编译器；如果构建 ARM 目标，需要安装对应 ARM
交叉编译器。

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
