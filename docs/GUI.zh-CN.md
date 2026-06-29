# GoN2N Windows 桌面 GUI

Flutter GUI 位于 `desktop_gui/`。当前目标只考虑 Windows。

## 已有功能

- 填写 n2n supernode 服务器地址和端口
- 自动生成社区名、共享密钥和虚拟 IP
- 导入 / 导出节点配置到剪切板
- 配置官方 n2n `edge.exe` 路径
- 连接和断开虚拟局域网
- 可选强制通过 supernode 中继
- 显示、复制 edge 实时日志
- 浅色 / 深色模式
- 自动保存配置

## 在 VS Code 中运行任务

打开命令面板，选择 `Tasks: Run Task`。

可用任务：

```text
GoN2N: Build Windows x64
Flutter GUI: Prepare Windows platform
Flutter GUI: Build Windows x64 release
```

## Windows GUI 构建要求

Windows 发布包必须在 Windows 上构建。需要安装：

1. Flutter SDK
2. Visual Studio 2022
3. Visual Studio 的“使用 C++ 的桌面开发”工作负载

然后运行：

```powershell
cd desktop_gui
flutter doctor
flutter build windows --release
```

结果位于：

```text
desktop_gui\build\windows\x64\runner\Release\
```

分发时必须复制整个 `Release` 文件夹。

## 运行要求

- 将兼容版本的 `edge.exe` 放到 GUI 同目录，或在界面填写完整路径
- 安装 TAP-Windows 驱动
- 使用管理员权限运行

Windows GUI 会通过 manifest 请求管理员权限。
