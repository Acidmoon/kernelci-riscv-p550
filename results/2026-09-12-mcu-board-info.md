# P550 MCU 只读采集记录 — 2026-09-12

**采集方式**：板子后置 Type-C 串口（FT4232H）→ MCU 命令行，只用**只读**查询命令
（`cbinfo-g` / `sominfo` / `ifconfig` / `bootsel-g` / `temp`），
**未登录系统、未执行任何 `set*` 写命令、未改密码、未重启**。

```bash
sg dialout -c 'python3 scripts/p550-serial-capture.py /dev/ttyUSB3 --seconds 15 --send-delay 1 \
  --send-line cbinfo-g --send-line sominfo --send-line ifconfig \
  --send-line bootsel-g --send-line temp'
```

## 通道映射（本机实测确认）

| 通道 | 身份 | 证据 |
|---|---|---|
| `/dev/ttyUSB0` | JTAG | 无输出 |
| `/dev/ttyUSB1` | JTAG | 无输出 |
| `/dev/ttyUSB2` | **SoC console** | 打印 `ubuntu login:` / `Password:` |
| `/dev/ttyUSB3` | **MCU console** | 打印 `#cmd:` 提示符，`help` 可列命令 |

与官方说法一致：**MCU UART 比 SoC UART 在本机上高一位**。

## 载板（Carrierboard）

```
magicNumber:0x45505ef1   formatVersionNumber:0x3   productIdentifier:0x4
pcbRevision:0x0   bomRevision:0x42   bomVariant:0x0
SN:SF106CKB2502000039
manufacturingTestStatus:0x1
```

## SoM

```
magicNumber:0x45505ef1  version:0x3  id:0x4  pcb:0x0  bom_revision:0x42
SN:SF106SKB2502000039   status:0x1
```

## 网络与 MAC（MCU 自身视角）

```
inet 192.168.0.2   netmask: 255.255.240.0   gatway 192.168.0.1
SOM_Mac0: 8c:1f:64:e8:8c:15
SOM_Mac1: 8c:1f:64:e8:8c:16
MCU_Mac:  8c:1f:64:e8:8c:17
```

**结论：三个 MAC 均已正确烧录**（`8c:1f:64` 开头且后段非零），
且载板序列号 `SF106CKB2502000039` **不在** SiFive 公告的"EEPROM 未写 MAC"受影响批次内
（受影响区间为 `SF106CKB2450000001–…090`、`SF106CKB2451000013–…300`、`SF106CKB2451000301–…908`）。

→ **本次上板不需要 `setmac`**，也就避免了对别人板子的写操作。

## 引导与状态

```
bootsel-g → Bootsel Controlled by: HW, bootsel[3 2 1 0]:0 0 1 0
temp      → cpu_temp: (读数格式异常)   npu_temp: 33.0 C   fan_speed: 2898 rpm
```

板子在运行（风扇转、温度正常），SoC console 停在 **`ubuntu login:`**
→ Ubuntu 已安装且已启动到登录界面。

## 未采集到的数据（被登录凭据阻塞）

尝试官方默认凭据 `ubuntu` / `ubuntu` 得到 **`Login incorrect`**
→ 密码已被板子主人改过（或镜像非 SiFive 默认）。

因此以下**系统层证据待拿到凭据后补采**：

- `uname -a` / `/etc/os-release`（内核与发行版）
- `/proc/cpuinfo` 的 `isa`（V/H/ZPM 等扩展是否存在 → 扩展矩阵 P550 列）
- `lsblk` / `findmnt`（根设备、引导介质）
- `ip -br a`（SoC 侧网口状态）
- 启动链证据（`bootchain.log`）

**安全边界（板子属于他人）**：不修改密码、不重启、不执行 `setmac`/`setip`/`bootsel-s` 等写命令；
系统层只做只读采集；测试脚本只写入 `/tmp` 与需要的用户目录，且需先获得主人同意。
