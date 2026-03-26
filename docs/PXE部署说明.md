# PXE 使用说明

本文档用于指导在当前仓库中使用 `runner.sh pxe` 部署和维护 PXE 服务，实现：

- 在全新环境中通过单条命令完成 PXE 基础部署
- 自动生成 `dnsmasq` 配置并准备 TFTP 启动文件
- 统一通过 `runner.sh` 管理 PXE 的安装、启动、停止和状态查看
- 将 PXE 服务部署与业务 `kernel` 发布解耦

---

## 1. 适用场景

- 需要在一台 Linux 主机上快速搭建 PXE 启动服务。
- 希望统一使用 `runner.sh` 管理，而不再单独维护 `pxe.sh` 主逻辑。
- 需要将仓库中的 PXE 模板文件渲染后部署到系统目录，例如：
  - `github-runners/pxe-boot/pxe-physical.conf` → `/etc/dnsmasq.d/pxe-physical.conf`
  - `github-runners/pxe-boot/boot.ipxe` → `<tftp-root>/boot.ipxe`
  - `github-runners/pxe-boot/grub-embedded.cfg` → 动态生成 `grubx64.efi`

---

## 2. 前置条件

- 一台 Linux 主机。
- 具备 `root` 或 `sudo` 权限。
- 目标网卡已经配置 IPv4 地址。
- 仓库中已包含 PXE 模板目录：

```text
github-runners/
├── runner.sh
└── pxe-boot/
    ├── pxe-physical.conf
    ├── boot.ipxe
    ├── grub-embedded.cfg
    └── ipxe-mb.efi
```

> 注意：`pxe --install` 现在默认不会发布 `kernel`。它负责准备 PXE 服务、iPXE 和 GRUB 引导链；`kernel` 或 `grub.cfg` 可以在后续由其他流程放入 TFTP 目录。

---

## 3. 命令入口

统一入口为：

```bash
./runner.sh pxe [options]
```

---

## 4. 快速开始

推荐首次部署命令：

```bash
sudo ./runner.sh pxe --install
```

如果需要指定网卡和模式：

```bash
sudo ./runner.sh pxe \
  --install \
  --interface eno1np0 \
  --mode proxy
```

部署完成后查看状态：

```bash
./runner.sh pxe --status
```

---

## 5. 常用命令

### 5.1 安装并部署

```bash
sudo ./runner.sh pxe --install
```

### 5.2 启动服务

```bash
sudo ./runner.sh pxe --start
```

### 5.3 停止服务

```bash
sudo ./runner.sh pxe --stop
```

### 5.4 查看状态

```bash
./runner.sh pxe --status
```

### 5.5 清理环境

```bash
sudo ./runner.sh pxe --clean
```

跳过确认：

```bash
sudo ./runner.sh pxe --clean --yes
```

---

## 6. 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--install` | 安装依赖、渲染配置、准备 TFTP 文件并启动服务 | - |
| `--start` | 启动 `dnsmasq` PXE 服务 | - |
| `--stop` | 停止 `dnsmasq` PXE 服务 | - |
| `--clean` | 清理 PXE 配置，并可选删除 TFTP 根目录 | - |
| `--status` | 查看当前 PXE 状态 | - |
| `--interface NAME` | 监听的网卡名 | `eno1np0` |
| `--server-ip IP` | 服务端 IP；实际部署时会校正为网卡当前 IPv4 | 自动探测 |
| `--client-ip IP` | 可选的静态客户端 IP，仅在需要为 GRUB 强制指定地址时使用 | 空 |
| `--mode MODE` | DHCP 模式：`proxy`、`exclusive`、`none` | `proxy` |
| `--tftp-root DIR` | TFTP 根目录 | `/home/root/test/x86_64-pc` |
| `--yes` | 清理时跳过确认 | `false` |

---

## 7. 部署产物

执行 `--install` 后，脚本会完成以下工作：

### 7.1 安装依赖

自动检查并按需安装：

- `dnsmasq`
- `iproute2`
- `grub-efi-amd64-bin`
- `ipxe`

### 7.2 生成系统配置

将模板渲染并写入：

```text
/etc/dnsmasq.d/pxe-physical.conf
```

同时确保 `/etc/dnsmasq.conf` 启用了：

```text
conf-dir=/etc/dnsmasq.d/,*.conf
```

### 7.3 准备 TFTP 目录

在 `<tftp-root>` 下准备：

- `ipxe-mb.efi`
- `undionly.kpxe`（若系统存在）
- `ipxe.efi`（若系统存在）
- `boot.ipxe`
- `autoexec.ipxe`
- `grubx64.efi`

默认不会主动复制 `kernel` 到 `<tftp-root>`。

---

## 8. DHCP 模式说明

### 8.1 `proxy` 模式

```bash
sudo ./runner.sh pxe --install --mode proxy
```

特点：

- 推荐默认模式。
- 适合网络中已存在 DHCP 服务器的场景。
- 当前主机只负责 PXE 引导相关响应，不直接分配完整地址池。

### 8.2 `exclusive` 模式

```bash
sudo ./runner.sh pxe --install --mode exclusive
```

特点：

- 当前主机独占提供 DHCP 服务。
- 会生成完整地址池配置。
- 不适合与已有 DHCP 服务器同时工作。

### 8.3 `none` 模式

```bash
sudo ./runner.sh pxe --install --mode none
```

特点：

- 仅提供 TFTP，不主动提供 DHCP 地址池。
- 适合由外部 DHCP 统一下发地址和 `next-server` 的场景。

---

## 9. 启动链说明

当前默认启动链为：

1. UEFI 固件通过 PXE 下载 `ipxe-mb.efi`
2. iPXE 加载 `boot.ipxe`（兼容场景下也可走 `autoexec.ipxe`）
3. `boot.ipxe` 链接到 `grubx64.efi`
4. `grubx64.efi` 优先尝试加载 `(tftp,<server-ip>)/grub.cfg`
5. 如果没有 `grub.cfg`，则尝试加载 `(tftp,<server-ip>)/kernel`
6. 如果两者都不存在，则停留在 GRUB 供人工调试

说明：

- 默认情况下，GRUB 只执行 `net_bootp` 获取地址，不再写死 `net_default_ip`
- 这对 `proxy` 模式更友好，因为 `proxy` 模式下客户端 IP 来自上游 DHCP，部署阶段通常无法预先知道
- 只有在特殊调试场景下，才建议显式传 `--client-ip`

---

## 10. 目录与模板说明

PXE 相关模板位于：

- [runner.sh](/home/root/github-runners/runner.sh)
- [pxe-physical.conf](/home/root/github-runners/pxe-boot/pxe-physical.conf)
- [autoexec.ipxe](/home/root/github-runners/pxe-boot/autoexec.ipxe)
- [grub-embedded.cfg](/home/root/github-runners/pxe-boot/grub-embedded.cfg)
- [boot.ipxe](/home/root/github-runners/pxe-boot/boot.ipxe)

其中：

- 必需的源文件：`pxe-physical.conf`、`boot.ipxe`、`autoexec.ipxe`、`grub-embedded.cfg`、`ipxe-mb.efi`
- 运行期生成文件：`grubx64.efi`
- `pxe-boot/` 中若存在 `grubx64.efi`，它更适合作为备份参考，不是部署时必须依赖的源文件

模板中的以下字段会在部署时动态替换：

- `__INTERFACE__`
- `__SERVER_IP__`
- `__CLIENT_IP__`
- `__DHCP_RANGE_LINE__`
- `__DHCP_HOST_LINE__`
- `__NO_DHCP_INTERFACE_LINE__`
- `__BIOS_BOOT_LINE__`
- `__FALLBACK_EFI_BOOT_LINE__`

---

## 11. 常见问题

### 11.1 执行时报错 “Network interface does not exist”

说明指定的网卡名不存在，可先查看系统网卡：

```bash
ip -o link show
```

然后重新指定：

```bash
sudo ./runner.sh pxe --install --interface <your-iface> --kernel /path/to/kernel
```

### 11.2 执行时报错找不到 `kernel`

`pxe --install` 本身不再要求 `kernel`。如果后续需要自动引导业务镜像，有两种方式：

```bash
cp /path/to/kernel <tftp-root>/kernel
```

或提供：

```bash
cp /path/to/grub.cfg <tftp-root>/grub.cfg
```

### 11.3 `dnsmasq` 启动失败

先检查配置测试：

```bash
sudo dnsmasq --test
```

再查看服务日志：

```bash
sudo journalctl -u dnsmasq -n 50 --no-pager
```

### 11.4 BIOS 客户端无法启动

当前实现会优先从系统中查找 `undionly.kpxe`。如果系统未安装对应文件，部署会继续，但 BIOS 引导能力会被禁用。

可重新执行安装以补齐依赖：

```bash
sudo ./runner.sh pxe --install
```

---

## 12. 推荐操作流程

日常推荐流程：

```bash
sudo ./runner.sh pxe --install --interface eno1np0 --mode proxy
./runner.sh pxe --status
```

如果只替换内核文件，可重新执行安装命令覆盖生成产物；如果只想重启服务，可执行：

```bash
sudo ./runner.sh pxe --stop
sudo ./runner.sh pxe --start
```
