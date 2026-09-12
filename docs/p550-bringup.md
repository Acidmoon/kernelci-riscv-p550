# P550 上板 Runbook（从零到 `ssh p550` 可用）

> 目标平台: **SiFive HiFive Premier P550**（ESWIN EIC7700 SoC，4×SiFive P550 核，出厂 Ubuntu 24.04）
> 本机: deepin x86_64（校园网走 WiFi，RJ45 空闲）
> 本文所有命令都是**你在本机/板子上执行**；每步都给了预期输出与验收标准，把真实输出贴回来即可继续。

---

## 0. 为什么是这套方案（先看结论）

| 判断 | 依据 |
|---|---|
| **P550 没有 WiFi，网线是唯一正路** | M.2 E-Key(SDIO WiFi) 在官方 FAQ 里明确 *not supported*；板子只有两个有线网口（Ubuntu 里 `end0`/`end1`） |
| **校园网不要直连板子** | 你们校园网需要 Portal/客户端认证；接入侧还常有客户端隔离/MAC 绑定。未认证设备插上就是不通 |
| **本机做 NAT 共享最稳** | 本机 WiFi 完成认证 → 本机 RJ45 开 `ipv4.method shared` → 板子自动拿 `10.42.0.x`，本机↔板子互通，板子还能借本机出口上网（`apt`/下载内核包） |
| **串口是前提，不是可选** | 板子后置 Type-C 带出 SoC debug UART，**不依赖任何网络**。有它你才敢改网络配置，也才能救砖 |
| **MAC 未烧录是这一批的已知坑** | 特定序列号批次 EEPROM 里没写 MAC → 网口 `8c:00:00:00:00:00` → DHCP 拿不到 IP → "SSH 不通"的头号嫌疑 |

**最终形态**：

```
进程0: [本机] --USB-C--> [P550]          串口控制台（带外，保命）
进程1: [本机WiFi] --校园网认证--> 互联网
       [本机RJ45] --网线--> [P550 end0]   10.42.0.0/24（本机 10.42.0.1 = DHCP+NAT）
       [本机] --ssh p550--> [P550]        与 lpi3a 并列的免密别名
```

---

## 1. 硬件连接

### 0.5 现场实测状态与安全边界（重要）

**2026-09-12 实测**（详见 [results/2026-09-12-mcu-board-info.md](../results/2026-09-12-mcu-board-info.md)）：

| 项 | 实测结果 |
|---|---|
| 通道映射 | `/dev/ttyUSB2` = **SoC console**（`ubuntu login:`）；`/dev/ttyUSB3` = **MCU console**（`#cmd:`）；`ttyUSB0/1` = JTAG |
| 板子状态 | 已上电运行，风扇 2898 rpm、npu 33°C，Ubuntu 停在登录界面 |
| 载板/SoM SN | `SF106CKB2502000039` / `SF106SKB2502000039` |
| MAC | 三个都已正确烧录（`8c:1f:64:e8:8c:15/16/17`）→ **不需要 `setmac`**，也不在官方受影响批次 |
| 登录 | 默认 `ubuntu`/`ubuntu` → `Login incorrect`（密码已被主人改过） |

> ⚠️ **如果板子不是你自己的**（本次情况即是）：
> **不修改密码、不重启、不执行任何 `set*` 写命令**（`setmac`/`setip`/`setmask`/`setgateway`/`bootsel-s`/`account-s`/`date-s`/`time-s`）。
> MCU 命令行里只读命令是：`cbinfo-g`、`sominfo`、`ifconfig`、`bootsel-g`、`temp`、`date`、`stats`、`help`。
> 系统层只做只读采集；上板测试需要先获得主人同意（会在 `~/KernelCI-pipeline` 与 `/tmp` 写文件）。
> 没有登录凭据时，**不要尝试爆破** —— 去问主人。

### 0.6 本机会话的 dialout 组坑（实测踩到）

`usermod -aG dialout` 之后**不注销重登**，会出现下面这个非常迷惑的状态：

```bash
id -nG            # 当前会话真实生效的组 → 没有 dialout ！
id -nG "$USER"    # 查组数据库         → 有 dialout
stty -F /dev/ttyUSB2 115200   # → stty: /dev/ttyUSB2: 权限不够（EACCES）
```

原因：`id -nG <用户名>` 查的是**组数据库**，`id -nG` 查的是**当前进程真实的补充组**。
所以"明明加了组还是权限不够"。两种解法：

```bash
# 免注销临时解法（推荐先用这个）：以 dialout 组身份跑单条命令
sg dialout -c 'python3 scripts/p550-serial-capture.py --all --seconds 5'

# 彻底生效：注销后重新登录
```

### 0.7 非交互抓取串口（不用 picocom，便于记录/自动化）

```bash
# 扫描 4 个通道并自动判断谁是 SoC / MCU（会拉高 DTR/RTS，部分板卡必须）
sg dialout -c 'python3 scripts/p550-serial-capture.py --all --seconds 5 --send-enter'

# 录一段启动日志
sg dialout -c 'python3 scripts/p550-serial-capture.py /dev/ttyUSB2 --seconds 30'

# 只读查询 MCU（绝不包含 set* 写命令）
sg dialout -c 'python3 scripts/p550-serial-capture.py /dev/ttyUSB3 --seconds 15 --send-delay 1 \
  --send-line cbinfo-g --send-line sominfo --send-line ifconfig --send-line bootsel-g'
```

### 0.8 实际采用的接入方式（2026-09-12 实测：校园网直连，NAT 方案未使用）

本环境里板子**已经直接挂在校园网上**，因此完全跳过了第 5 节的 NAT 共享：

```
end1  UP  10.13.22.70/20  （板子）
本机  wlp5s0 UP 10.8.36.167/16   → ping 10.13.22.70 通（3.5ms），22 端口开放
```

实际步骤（比默认方案少很多）：

```bash
# 1) 串口登录（板子已开机，停在 ubuntu login:）
sg dialout -c 'python3 scripts/p550-serial-capture.py /dev/ttyUSB2 --seconds 20 --send-delay 2 \
  --send-line "<用户名>" --send-line "<密码>" --send-line "uname -a; ip -br a"'

# 2) 把本机公钥装进板子的 ~/.ssh/authorized_keys（等价 ssh-copy-id，用串口做）
#    幂等；只需一次。命令略，见 results/2026-09-12-mcu-board-info.md 的说明

# 3) 本机 ~/.ssh/config 增加别名
Host p550
    HostName 10.13.22.70
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519

# 4) 跑流水线
bash scripts/run-board-tests.sh        # → OVERALL: PASS
```

> ⚠️ **对他人板子所做的唯一改动**：向 `~/.ssh/authorized_keys` 追加了本机公钥（以及新建了
> `~/KernelCI-pipeline` 测试脚本目录）。清理方式：
> ```bash
> ssh p550 'sed -i "/Acidmoon@github/d" ~/.ssh/authorized_keys; rm -rf ~/KernelCI-pipeline'
> ```
> 除此之外**未改密码、未重启、未加载内核模块、未执行任何 `set*` 写命令**。

### 0.9 校验失败时的经典错误：scp `dest open "…": Failure`

`run-board-tests.sh` 早期版本在板上测试目录不存在时会直接 scp，报这个很费解的错误。
现已改为**先 `ssh mkdir -p $TESTS_DIR` 再同步**。如果你看到这条，说明 `TESTS_DIR` 不存在或不可写。

### 0.10 真机 Hypervisor（H/KVM）——P550 独有路径

P550 是唯一带 **H 扩展**的真机（li3a 没有），所以真机 Hypervisor 测试只能在这里做。
SOW 点名的两个扩展轴是 Vector / Hypervisor：Vector 由 li3a 覆盖，Hypervisor 由 P550 覆盖。

**现状与一次性的三件事**（`/dev/kvm` 默认 `crw------- root root`，且 kvm 模块默认不加载，
所以普通用户/CI 打不开）：

```bash
# 在板子上执行（脚本已随流水线同步到 ~/KernelCI-pipeline/）
sudo bash p550-kvm-setup.sh              # 应用：modules-load.d + udev 规则 + 用户加入 kvm 组
sudo bash p550-kvm-setup.sh --status     # 查看
sudo bash p550-kvm-setup.sh --undo       # 完全撤销（三个改动全部还原）
```

做的是三件标准且可逆的事：`/etc/modules-load.d/kvm.conf`（开机加载 kvm）、
`/etc/udev/rules.d/60-p550-kvm.rules`（`/dev/kvm` 归 `kvm` 组、0660）、
`usermod -aG kvm <用户>`。**不碰网络/SSH/登录/密码**；组身份对新登录会话生效（重连 SSH 即可）。

验证：

```bash
ssh p550 'dmesg | grep -i kvm | tail -3'      # 期望: hypervisor extension available / Sv48x4 G-stage / VMID 0 bits
bash scripts/run-board-tests.sh               # 期望: hypervisor: PASS
```

测试本身（`tests/riscv_kvm_smoke.c`）不需要 qemu、不需要客户机镜像：自己创建 VM/vCPU、
注册 4 KiB guest 内存、写入三条 RV64 指令（`lui`/`lw`/`jal`），让客户机访存未映射的
`0x1000_0000`，然后断言退出原因确实是 `KVM_EXIT_MMIO`。

⚠️ 注意 **板子上没有 gcc**，所以这个二进制由本机交叉编译（`HOST_CC`，默认
`riscv64-linux-gnu-gcc`）后同步过去；流水线第 [1] 步会自动做这件事。


1. ATX 电源接好（注意 FAQ 里"部分 ATX 电源与 P550 不兼容"的清单）。
2. **USB-C 数据线**（不是充电线）：板子**后置 Type-C（USB2.0）** ↔ 本机 USB。
3. 网线：板子 **`end0`** ↔ 本机 **RJ45**（此时先不接校园网）。
4. 板载拨动开关打到 ON，**先别按 PWR 键**（先把串口终端开起来）。

---

## 2. Phase 0 — 串口控制台（带外通道）

```bash
# ── 本机 ──
sudo apt install -y picocom
bash scripts/p550-serial.sh list        # 看设备、brltty 抢占、dialout 权限
bash scripts/p550-serial.sh probe       # 逐通道试读 3 秒，自动判断 SoC/MCU
```

没有 helper 时的手工版：

```bash
ls -l /dev/serial/by-id/                                  # FTDI Quad RS232-HS 的多个通道
sudo dmesg | grep -iE 'ftdi|usbserial|ttyUSB' | tail -20
sudo usermod -aG dialout $USER                            # 之后注销重登
sudo picocom -b 115200 /dev/ttyUSB2                       # 退出: Ctrl-A 再 Ctrl-X
```

**通道映射经验值**（SiFive FAQ + 官方文档）：

| 通道 | by-id | 典型设备 | 特征 |
|---|---|---|---|
| SoC console | `if02` | `/dev/ttyUSB2` | U-Boot banner、内核日志、`login:` |
| MCU console | `if03` | `/dev/ttyUSB3` | `ifconfig` / `setmac` / `version` / `account-s` 可用 |

> **MCU UART 永远比 SoC UART 在本机上高一位**（官方 FAQ 原文）。别死记编号，用 `p550-serial.sh probe` 按行为判断。

**操作顺序**：先开 picocom，**再按板上 PWR 键（S3）上电** —— 这样能看到完整启动日志。

- **预期输出**：`U-Boot 20xx.xx` → `Hit any key to stop autoboot` → 内核日志 → `ubuntu login:`
- **验收**：能连续看到完整日志，并能在 autoboot 处按键停住。
- **卡点**：
  - 设备出现又消失/打不开 → `sudo apt remove -y brltty`（deepin 上 brltty 抢占 FTDI 的经典坑）
  - 满屏乱码 → 通道或波特率不对（JTAG 通道不会有可读文本）
  - 什么设备都没有 → 换线（多数 Type-C 线是纯充电线）、换 USB 口、避开 Hub
  - **`Device or resource busy`（板子/线/驱动/权限都正常却打不开）→ 见下面「ModemManager 抢占串口」**

### Phase 0 常见卡点：ModemManager 抢占串口

Debian/Ubuntu 系桌面上 `ModemManager` 默认在跑，它会把 FTDI 串口当"调制解调器"探测并占用，
症状是 `stty`/`picocom` 报 **`Device or resource busy`**，而 `ls -l /dev/ttyUSB*` 权限完全正常
（`crw-rw---- root dialout`）、`ftdi_sio` 也绑定正常。

先确认真实错误（别被笼统提示误导）：

```bash
ls -l /dev/ttyUSB*                                   # 应为 crw-rw---- root dialout
stty -F /dev/ttyUSB2 115200; echo "rc=$?"            # 这里会打印真正的错误
systemctl is-active ModemManager brltty brltty-udev  # 看哪个服务在跑
sudo fuser -v /dev/ttyUSB2                           # 看谁占着
```

修复（任选）：

```bash
# A) 临时验证
sudo systemctl stop ModemManager

# B) 永久 + 只影响这个设备（推荐；规则文件在本仓库 udev/ 下）
sudo cp udev/99-p550-serial.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
# 然后重新插拔 USB-C 线

# C) 你完全不用移动宽带功能
sudo systemctl mask ModemManager
```

---

## 3. Phase 1 — 登录与系统建档

```bash
# 串口里
ubuntu / ubuntu        # SiFive 官方 Ubuntu 默认；首次登录会强制改密码，记住新密码
```

> FAQ 原文：*Default username and password for SiFive's Ubuntu releases — Username: ubuntu / Password: ubuntu*。
> Getting Started Guide 里写的 Yocto 账号是旧的，别照着试。

登录后立刻建档（把输出贴回来）：

```bash
uname -a
cat /etc/os-release | head -3
ip -br a
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
nproc; free -h
```

判读要点：

| 观察 | 结论 |
|---|---|
| `uname -a` 带 `-premier` 后缀 | 基本是 SiFive/ESWIN 的 P550 Ubuntu 镜像 |
| `link/ether` = `8c:00:00:00:00:00` 或 `8c:1f:00:...` | **出厂 MAC 未烧录** → 进 Phase 2 |
| `lsblk` 看到 ~128G 的 `mmcblk0` | 出厂 eMMC 引导 |
| 只有 IPv6、没有 `inet` | DHCP 没起来，多半还是 MAC 问题 |

**登不进 `ubuntu/ubuntu` 时的 GRUB 恢复法**（OS 来源不明时用）：

1. 上电，在 U-Boot `Hit any key to stop autoboot` 按键进入引导菜单。
2. GRUB 菜单选中启动项按 `e`，在 `linux` 行末尾追加 `init=/bin/bash`，Ctrl-X 启动。
3. 得到 shell 后：

```bash
mount -o remount,rw /
cat /etc/passwd            # 看有哪些用户
passwd ubuntu              # 重设密码
exec /sbin/init            # 或 sync; reboot -f
```

---

## 4. Phase 2 — 修 MAC（仅当 Phase 1 判定需要）

**只有**网口 MAC 是 `8c:00:00:00:00:00` / `8c:1f:00:...` 时才需要做。板上两个网口旁边有**3 张贴纸**（MCU + 两个 GMAC 各一个 MAC），拿它们当正确值。

在 **MCU 串口**（`/dev/ttyUSB3`，用 `bash scripts/p550-serial.sh open mcu`）：

```
ifconfig                                  # 读当前 MAC，确认异常
setmac <索引> <贴纸上的MAC>                # 逐个写入
ifconfig                                  # 复核
```

- 写完**必须完全断电重启**（板载拨动开关或断 ATX），**不是** `reboot`。
- **验收**：Ubuntu 里 `ip -br a` 的 `end0`/`end1` MAC 等于贴纸值且互不相同。
- 官方也提供 ESWIN 的图形化工具（备选）：[sifiveinc/hifive-premier-p550-tools](https://github.com/sifiveinc/hifive-premier-p550-tools) 里的 `es-mac-id-update-tool`。

---

## 5. Phase 3 — 本机 RJ45 共享网络给板子

```bash
# ── 本机 ──
bash scripts/p550-net-share.sh setup      # 自动挑空闲有线网口，创建 p550-shared
bash scripts/p550-net-share.sh status
```

手工等价命令：

```bash
nmcli device status
nmcli con add type ethernet ifname <网口> con-name p550-shared ipv4.method shared
nmcli con modify p550-shared ipv4.never-default yes ipv4.ignore-auto-dns yes
nmcli con up p550-shared
```

要点：

- `ipv4.method shared` 让本机变成 DHCP 服务器 + NAT 网关（本机 `10.42.0.1`）。
- `ipv4.never-default yes` 防止共享网口抢走默认路由导致**本机自己断网**。
- 共享模式依赖 `dnsmasq`：`sudo apt install -y dnsmasq-base`。
- 本机 ufw/firewalld 可能挡转发，先 `sudo ufw status`。

板子侧接线后确认：

```bash
# 串口里
ip -br a                                  # end0 应为 UP,LOWER_UP，并拿到 10.42.0.x
ip route                                  # 默认路由指向 10.42.0.1
ping -c3 10.42.0.1
curl -sI https://kernel.org | head -1     # 有响应 = NAT/DNS 都通
```

**找板子 IP**：

```bash
bash scripts/p550-net-share.sh find       # 邻居表 + mDNS + arp-scan
# 板子拿不到 IP 的两大原因: (1) MAC 未烧(回 Phase 2) (2) 网线不在 end0 / link down
```

---

## 6. Phase 4 — SSH 别名与免密

```bash
bash scripts/p550-net-share.sh write-ssh-config   # 自动写入 ~/.ssh/config（含备份）
ssh-copy-id p550                                  # 密码用你改过的那个
ssh p550 'uname -m; uname -r; nproc; ip -br a'
```

写入的片段：

```
Host p550
    HostName 10.42.0.x
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
```

**验收（硬标准）**：输出 `riscv64` + 内核版本 + `4` + `10.42.0.x`。

---

## 7. 总体验收清单

- [ ] 串口能看到完整 U-Boot/内核日志，并能在 autoboot 处停住
- [ ] 能以 `ubuntu` 登录，且已改密码
- [ ] `ip -br a` 里 `end0`/`end1` MAC 正常且互不相同（或已完成 setmac + 完全断电重启）
- [ ] 板子 `end0` 拿到 `10.42.0.x`，`ping 10.42.0.1` 通
- [ ] 板子 `curl -sI https://kernel.org` 有 HTTP 响应（NAT 通）
- [ ] 本机 `ssh p550 'uname -m'` 返回 `riscv64`
- [ ] `bash scripts/p550-doctor.sh` 全绿
- [ ] `bash scripts/run-board-tests.sh` 跑通并产出 `results/history/<ts>/results.json`

---

## 8. 故障排查

| 现象 | 最可能原因 | 处理 |
|---|---|---|
| 串口无任何设备 | 充电线 / USB Hub / brltty 抢占 | 换数据线、直插、`sudo apt remove -y brltty` |
| 串口打不开 | 不在 dialout 组 | `sudo usermod -aG dialout $USER` 后注销重登 |
| 串口报 `Device or resource busy` | **ModemManager 占用**（权限/驱动都正常） | 见 Phase 0 的 ModemManager 小节，装 `udev/99-p550-serial.rules` |
| 打开后满屏乱码 | 通道或波特率不对 | 用 `p550-serial.sh probe`；波特率必须 115200 |
| 看到 `setmac` 等命令 | 开的是 MCU 通道 | 换高/低一位（MCU 比 SoC 高一位） |
| `ubuntu/ubuntu` 登不进 | 镜像不是 SiFive 版 / 密码被改过 | GRUB `init=/bin/bash` 重设密码（见第 3 节） |
| 网口 MAC 全是 0 | 出厂 EEPROM 未烧录 | Phase 2 setmac + 完全断电重启 |
| `end0` 是 `NO-CARRIER` | 网线没插对/线坏/板子没起来 | 换口换线；确认板子已进系统 |
| 板子拿不到 `10.42.0.x` | MAC 未烧 / dnsmasq 缺失 / ufw 拦截 | 按序查 Phase 2、`dnsmasq-base`、`sudo ufw status` |
| 本机共享后自己断网 | 共享网口抢了默认路由 | `nmcli con modify p550-shared ipv4.never-default yes` 并重连 |
| 板子上不了外网但能 ping 本机 | NAT/转发未生效 | 检查 ufw/firewalld、`sysctl net.ipv4.ip_forward` |
| 板子第一次开机几分钟没网 | cloud-init 还在跑 | 等 `cloud-init ... finished` 再判断 |

---

## 9. P550 专属坑位（记住能省几小时）

| 坑 | 说明 |
|---|---|
| ATX 电源兼容性 | 官方 FAQ 有"电源不工作"清单，上电无反应先换电源 |
| 只能挂一个可引导介质 | 同时插 eMMC/SD/NVMe/USB 会"随机选盘" |
| eMMC 是出厂引导 | 要换 SATA/NVMe/USB/SD 有专门的 U-Boot `es_fs` 流程 |
| M.2 E-Key SDIO WiFi | 明确不支持，别在这上面花时间；要无线用 FAQ 列的 USB WiFi 网卡 |
| MCU 也是 BMC | 板载 STM32F407 有串口 CLI + Web 界面（`http://<MCUIP>/login.html`）；Collabora/RISE 就是用它做远程**电源控制 + boot mode 切换**（后期 LAVA 化不用另买 PDU） |
| NAT 后面板子不可被外部访问 | 所以本方案只用于 Phase 1–2；做 LAVA/Boardswarm（lab 主动连板子）时要换独立路由器或给板子做校园网注册 |

---

## 10. 参考链接

- SiFive 官方 FAQ（默认账号、MAC 未烧录、电源、启动介质）: <https://www.sifive.com/development-platforms/hifive-premier-p550/faq>
- Ubuntu P550 镜像与 UART 说明（SoC console=`/dev/ttyUSB2`, 115200）: <http://people.ubuntu.com/~xypron/hifive_premier_p550/>
- MAC-ID 未烧录公告（受影响序列号）: <https://forums.sifive.com/t/mac-id-update-for-boards-with-missing-mac-ids/7189>
- 网口/MAC/DHCP 讨论（含官方回复：MAC 修好后 DHCP 正常）: <https://forums.sifive.com/t/ethernet-adaptor/6905>
- Getting Started Guide（串口终端设置、DIP、按键）: <https://www.sifive.com/document-file/hifive-premier-p550-getting-started-guide>
- MCU 用户手册（`ifconfig`/`setmac` 在 3.1.1 节）: <https://www.sifive.com/document-file/premier-p550-mcu-user-manual>
- P550 工具集（含 ESWIN MAC 更新工具）: <https://github.com/sifiveinc/hifive-premier-p550-tools>
- RISE RP012 / Collabora 的 P550 LAVA lab 接入（MCU 电源控制 + fastboot）: <https://test.www.collabora.com/news-and-blog/news-and-events/tested-on-real-silicon-automating-risc-v-hardware-in-the-loop.html>
- P550 板级 LAVA 文档（该站有 Anubis 反爬，用浏览器打开）: <https://lava.pages.collabora.com/docs/boards/eic7700-hifive-premier-p550/>
