# GoN2N Windows 桌面 GUI

Flutter GUI 位于 `desktop_gui/`。当前发布目标是 Windows x64。

## 已有功能

- 填写 n2n supernode 服务器地址和端口
- 自动补全社区名、成员服务地址、虚拟 IP 和共享密钥
- 导入 / 导出节点配置到剪切板
- 配置官方 n2n `edge.exe` 路径
- 连接和断开虚拟局域网
- 强制通过 n2n supernode 中继
- 提高虚拟网卡跃点优先级
- 在线成员列表
- 网络状态检查
- TCP / UDP 连通性测试
- 延迟、丢包和连接模式显示
- 非用户主动断开时自动重连
- TAP-Windows 网卡检测和安装提示
- 显示、复制 edge 实时日志
- 简略 / 详细日志视图
- 浅色 / 深色模式
- 关于窗口和项目主页入口
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
