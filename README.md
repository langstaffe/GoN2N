# GoN2N

GoN2N 是一个面向 Windows 客户端的 n2n 图形化工具。它通过 n2n `edge`
加入虚拟局域网，并提供在线成员列表、网络状态检查、TCP/UDP 连通性测试、
TAP 网卡检测与安装提示等功能。

GoN2N 本身不替代 n2n。实际的数据转发、加密、NAT 穿透和 supernode 中继仍由
n2n 完成；GoN2N 负责把连接配置、客户端体验和成员在线状态做得更容易使用。

## 一、前期准备

你需要准备一台云服务器，用来运行：

- n2n `supernode`
- GoN2N `member-server`

建议在云服务器安全组、防火墙中放行：

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 51873 | TCP/UDP | n2n 服务器端口 |
| 51874 | TCP | GoN2N 在线成员服务 |

如果云服务器系统本身还启用了防火墙，也需要同步放行：

```bash
sudo ufw allow 51873/tcp
sudo ufw allow 51873/udp
sudo ufw allow 51874/tcp
```

如果没有使用 `ufw`，请按你的系统防火墙工具放行相同端口。

## 二、安装

### 2.1 服务器安装 n2n

GoN2N 客户端需要连接到 n2n `supernode`。你可以使用自己编译的 n2n，也可以使用
系统包或官方发布包，只要服务器端和客户端 `edge.exe` 协议兼容即可。

假设已经得到 `supernode` 可执行文件，可以放到：

GoN2N patched n2n release artifact name: `n2nR-linux-amd64`.

```bash
./scripts/build-n2nr-linux-amd64.sh
sudo install -m 755 dist/n2nR-linux-amd64 /usr/local/bin/n2nR
```

创建 systemd 服务：

```bash
sudo nano /etc/systemd/system/n2n-supernode.service
```

写入：

```ini
[Unit]
Description=n2n Supernode
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/n2nR -p 51873 --gon2n-fast-reconnect -V v0.1.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

启动并设置开机自启：

```bash
sudo systemctl daemon-reload
sudo systemctl enable n2n-supernode
sudo systemctl start n2n-supernode
sudo systemctl status n2n-supernode --no-pager -l
```

确认端口监听：

```bash
sudo ss -lntup | grep 51873
```

### 2.2 服务器安装 gon2n-member-server

`gon2n-member-server` 用于维护 GoN2N 的在线成员列表。它不转发游戏流量，只处理
客户端心跳、成员列表和地址租约。

将发布包中的 Linux 服务端文件上传到服务器，例如：

```bash
sudo mkdir -p /opt/gon2n
sudo install -m 755 gon2n-member-server-linux-amd64 /opt/gon2n/gon2n-member-server
```

创建 systemd 服务：

```bash
sudo nano /etc/systemd/system/gon2n-member-server.service
```

写入：

```ini
[Unit]
Description=GoN2N Member Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/gon2n/gon2n-member-server member-server --listen :51874 --lease 30s
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

启动并设置开机自启：

```bash
sudo systemctl daemon-reload
sudo systemctl enable gon2n-member-server
sudo systemctl start gon2n-member-server
sudo systemctl status gon2n-member-server --no-pager -l
```

确认服务可用：

```bash
curl http://127.0.0.1:51874/healthz
```

正常会返回：

```text
ok
```

从本机电脑测试云服务器公网访问：

```powershell
curl.exe http://服务器公网IP:51874/healthz
```

### 2.3 客户端安装 GoN2N

在 Windows 客户端下载 GoN2N Windows x64 发布包，解压后运行：

```text
GoN2N.exe
```

第一次运行可能会出现 Windows SmartScreen 提示，这是因为程序没有代码签名。
如果你确认来源可信，可以点击“更多信息”，再选择“仍要运行”。

GoN2N 需要管理员权限，因为 n2n `edge.exe` 需要操作 TAP 网卡和虚拟网络配置。

客户端需要填写：

| 字段 | 说明 |
| --- | --- |
| 服务器地址 | 云服务器公网 IP 或域名 |
| 端口 | n2n supernode 端口，默认可使用 `51873` |
| 社区名 | 同一虚拟局域网内必须一致 |
| 本机昵称 | 显示在在线成员列表中的名称 |
| 成员服务地址 | 例如 `http://服务器公网IP:51874` |
| 虚拟 IP | 本机在虚拟局域网中的 IP |
| 共享密钥 | 同一虚拟局域网内必须一致 |
| edge 程序路径 | 一般会自动识别发布包内的 `edge.exe` |

如果电脑没有 TAP-Windows 网卡，GoN2N 会提示安装。安装 TAP 驱动时同样需要管理员权限。

同一个虚拟局域网内：

- 服务器地址、端口、社区名、共享密钥必须一致
- 每台电脑的虚拟 IP 必须不同
- 虚拟 IP 建议使用同一个网段，例如 `10.239.180.x`

连接成功后，可以在右侧在线成员列表中查看同社区成员，并使用“网络状态检查”测试
延迟、TCP、UDP、丢包和连接模式。

## 三、维护

### 3.1 服务端更新 n2n

更新 `supernode` 时建议先停止服务：

```bash
sudo systemctl stop n2n-supernode
```

替换二进制文件：

```bash
sudo install -m 755 dist/n2nR-linux-amd64 /usr/local/bin/n2nR
```

重新启动：

```bash
sudo systemctl start n2n-supernode
sudo systemctl status n2n-supernode --no-pager -l
```

查看日志：

```bash
sudo journalctl -u n2n-supernode -f
```

### 3.2 服务器更新 gon2n-member-server

先停止服务：

```bash
sudo systemctl stop gon2n-member-server
```

替换二进制文件：

```bash
sudo install -m 755 gon2n-member-server-linux-amd64 /opt/gon2n/gon2n-member-server
```

重新启动：

```bash
sudo systemctl start gon2n-member-server
sudo systemctl status gon2n-member-server --no-pager -l
```

确认接口正常：

```bash
curl http://127.0.0.1:51874/healthz
```

查看日志：

```bash
sudo journalctl -u gon2n-member-server -f
```

### 3.3 客户端更新 GoN2N

更新 Windows 客户端时：

1. 先在 GoN2N 中断开连接。
2. 退出 GoN2N。
3. 下载新的 Windows x64 发布包。
4. 解压到一个新的文件夹，或覆盖旧文件夹。
5. 重新运行 `GoN2N.exe`。

发布包内通常包含：

```text
GoN2N.exe
GoN2N_files/
```

请保持 `GoN2N.exe` 和 `GoN2N_files` 在同一个目录下，不要只单独复制
`GoN2N.exe`。

GoN2N 的本机配置保存在用户目录中，替换程序文件通常不会清空已经填写过的配置。

## 安全提示

- 不要公开分享社区名和共享密钥。
- 不要把包含真实服务器地址、社区名和共享密钥的导出配置发布到公开仓库。
- 如果多人共用同一个虚拟局域网，建议使用足够长的随机共享密钥。
- 如果怀疑共享密钥泄露，请同时修改所有客户端配置。

## 第三方组件

GoN2N 使用 n2n 作为虚拟局域网数据层。第三方组件说明见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
