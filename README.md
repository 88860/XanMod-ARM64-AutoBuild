<div align="center">

# XanMod-ARM64-AutoBuild

**ARM64 (aarch64) 原生编译 · XanMod 内核自动构建仓库**

[![Channels](https://img.shields.io/badge/Channels-EDGE%20%7C%20MAIN%20%7C%20LTS-00b894?style=flat-square)](https://github.com/88860/XanMod-ARM64-AutoBuild/releases)
[![Arch](https://img.shields.io/badge/Arch-ARM64%20aarch64-4eaa25?style=flat-square)](https://www.kernel.org/)
[![Toolchain](https://img.shields.io/badge/Toolchain-LLVM%20%2F%20Clang%2022-0984e3?style=flat-square)](https://llvm.org/)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions%20Native%20ARM64-e84393?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/88860/XanMod-ARM64-AutoBuild/actions/workflows/xanmod-arm64.yml)

**简体中文** | [English](README_EN.md)

[项目概览](#项目概览) · [特性说明](#特性说明) · [命名规范与上游对齐](#命名规范与上游对齐) · [x86_64 配置移植机制](#x86_64-配置移植机制) · [构建流水线](#构建流水线) · [发布产物与安装方式](#发布产物与安装方式) · [安装脚本](#安装脚本xanmod-installsh) · [安全与校验](#安全与校验) · [常见问题与注意事项](#常见问题与注意事项)

</div>

---

## 项目概览

`XanMod-ARM64-AutoBuild` 面向 **Debian / Ubuntu ARM64 (`aarch64`)** 系统提供 XanMod 内核的自动构建与发布。上游 XanMod 官方仓库主要分发 `amd64`（`x64v1` / `x64v2` / `x64v3`）二进制包；本仓库基于 GitHub Actions ARM64 运行器（`ubuntu-24.04-arm`）与 **LLVM / Clang 22** 工具链，每日跟踪 [GitLab XanMod Linux](https://gitlab.com/xanmod/linux) 的 **EDGE**、**MAIN**、**LTS** 分支，将 XanMod 内核补丁与 `x86_64` 配置选项移植至 ARM64 后生成标准 `.deb` 包并发布到 GitHub Releases。

> [!IMPORTANT]
> **构建环境**：GitHub Actions `ubuntu-24.04-arm`（`aarch64`）运行器，原生架构编译。  
> **适用系统**：Debian / Ubuntu（`arm64` 架构；[xanmod-install.sh](xanmod-install.sh) 亦适配 `amd64` 官方 APT 源）。

---

## 特性说明

* **多通道矩阵调度与隔离**：单一工作流 [`.github/workflows/xanmod-arm64.yml`](.github/workflows/xanmod-arm64.yml) 通过矩阵管理 `edge`、`main`、`lts` 三条分支，并配置 `fail-fast: false`，单通道异常不会阻塞其余通道构建发布。
* **与上游对齐的包命名**：`uname -r`、`.deb` `Package` 名、`KDEB_PKGVERSION`（含提交日期与 7 位短哈希）及产物文件名遵循上游 `.gitlab-ci.yml` 规范，仅将 `x64v*` / `amd64` 架构后缀替换为 `arm64`。
* **Kconfig 作用域与互斥组移植**：以 `arm64 defconfig` 为基础配置，按 Kconfig 架构作用域与 `choice ... endchoice` 互斥组规则移植 XanMod 的调度、抢占、网络、内存、I/O 与加固选项，保留 ARM64 引导与基础设备驱动。
* **原生 LLVM/Clang 构建**：全程使用 `ARCH=arm64 LLVM=1`（`clang-22`、`ld.lld-22`、`llvm-ar-22` 等），不设置 `CROSS_COMPILE`，避免 `linux-headers` 阶段生成 GCC 主机工具。
* **构建后验证**：发布前执行上游 Commit SHA 核对、`.config.final` 字节比对、`dpkg-deb` 包结构检查及 `SHA256SUMS` 生成。
* **签名 APT 仓库与元包**：为 `main` / `edge` / `lts` 生成对应通道元包（`linux-xanmod[-edge|-lts]-arm64`），并通过 GitHub Pages 发布 GPG 签名 APT 仓库以支持 `apt update && apt upgrade` 自动升级。

---

## 命名规范与上游对齐

对照上游 `xanmod/linux` 的 `.gitlab-ci.yml`、`scripts/setlocalversion` 与 `scripts/package/mkdebian`，除架构标识由 `x64v*` / `amd64` 映射为 `arm64` 外，其余命名字段与官方规则一致：

| 命名项目 | XanMod 官方（以 `x64v3` 为例） | 本项目（`arm64`） |
| :--- | :--- | :--- |
| **`CONFIG_LOCALVERSION`** | `"-x64v3"` | `"-arm64"` |
| **`localversion` 文件** | `"-xanmod1"`（上游源码自带） | `"-xanmod1"`（随上游 Tag 保留 `-${TAG#*-}`） |
| **`KERNELRELEASE` / `uname -r`** | `7.3.6-x64v3-xanmod1` | `7.3.6-arm64-xanmod1` |
| **`KDEB_PKGVERSION` (`Version`)** | `7.3.6-x64v3-xanmod1-0~20261123.g6b041b1` | `7.3.6-arm64-xanmod1-0~20261123.g6b041b1` |
| **内核镜像包 (`Package`)** | `linux-image-7.3.6-x64v3-xanmod1` | `linux-image-7.3.6-arm64-xanmod1` |
| **头文件包 (`Package`)** | `linux-headers-7.3.6-x64v3-xanmod1` | `linux-headers-7.3.6-arm64-xanmod1` |
| **`.deb` 文件名示例** | `linux-image-7.3.6-x64v3-xanmod1_7.3.6-x64v3-xanmod1-0~20261123.g6b041b1_amd64.deb` | `linux-image-7.3.6-arm64-xanmod1_7.3.6-arm64-xanmod1-0~20261123.g6b041b1_arm64.deb` |
| **通道隔离标识** | APT 元包（`linux-xanmod[-edge\|-lts]-x64v3`）与 SourceForge 分目录 | APT 元包（`linux-xanmod[-edge\|-lts]-arm64`）及 Release Tag 后缀（`<KERNELRELEASE>-<channel>`） |

> [!NOTE]
> **关于同版本通道隔离**：XanMod 官方内核名及 `.deb` 包名本身不携带 `main`/`edge`/`lts` 后缀。本项目仅在 **GitHub Release Tag** 上附加 `-${CHANNEL}`（例如 `7.3.6-arm64-xanmod1-main`、`7.3.1-arm64-xanmod1-edge`、`6.18.65-arm64-xanmod1-lts`），确保三个通道在同一仓库共存时不会互相覆盖或误删旧版；若 `edge` 与 `main` 恰好追踪到同一个上游 Tag，二者在本机对应同一份同配置内核包。

---

## x86_64 配置移植机制

XanMod 的行为调整来自两部分：**内核源码补丁**（如 BBRv3、`PREEMPT_LAZY`、`sched_ext`、futex/`ntsync` 等）与 **`CONFIGS/x86_64/config`**。工作流按以下四步将配置移植至 ARM64：

### 1. 移植流程

1. **ARM64 基础配置**：以 `make ARCH=arm64 LLVM=1 defconfig` 生成初始配置，保留设备树（`CONFIG_OF`）、串口控制台（如 PL011）、ACPI/EFI 引导、GIC 中断控制器与 LSE/PAC/BTI 运行时补丁支持。
2. **架构作用域过滤**：扫描 Kconfig 时剪枝非 `arm64` 的 `arch/*` 目录，提取通用子系统与 ARM64 适用的 `CONFIG_*` 启用项；跳过 `CONFIG_NR_CPUS=8192`（超出 `arch/arm64/Kconfig` 的 `2..4096` 范围），保留 ARM64 默认 `512`。
3. **`choice ... endchoice` 互斥组处理**：
   * 上游 `CONFIGS/x86_64/config` 含 `# CONFIG_OF is not set` 等 x86 禁用项，不能整表套用；
   * 构建脚本中的 Python 解析器识别 `choice ... endchoice` 单选组：当 XanMod 选中某组内对 ARM64 有效的 `=y` 选项时，同步禁用该组内冲突的 ARM64 默认项（例如 `CONFIG_PREEMPT`、`CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`、`CONFIG_IOMMU_DEFAULT_DMA_STRICT`、`CONFIG_DEFAULT_CUBIC`、`CONFIG_DEFAULT_PFIFO_FAST` 等）；
   * 同时引入已确认安全的关闭项（如 `DEBUG_PREEMPT`、`PREEMPT_TRACER`、`RCU_LAZY_DEFAULT_OFF`、`WERROR`、`OBJTOOL_WERROR` 等）。
4. **防降级合并与核对**：
   * 使用 `./scripts/kconfig/merge_config.sh -m -y .config xanmod.arm64.fragment` 合并片段，`-y` 防止 `arm64 defconfig` 中的内建 `=y` 驱动（如 `CONFIG_KVM`、`CONFIG_VIRTIO_NET`、`CONFIG_VIRTIO_MMIO`、`CONFIG_VIRTIO_BALLOON` 等）被上游的 `=m` 降级为模块；
   * 执行 `olddefconfig` 与 `syncconfig` 后，向 Job Summary 输出已移植选项对照表；若有选项被 Kconfig 依赖裁剪，则输出 `::warning::` 告警。

### 2. 已移植选项概览

| 优化领域 | 主要移植选项（随上游版本可用性自动生效） |
| :--- | :--- |
| **调度与低延迟抢占** | `CONFIG_PREEMPT_LAZY=y`、`CONFIG_PREEMPT_DYNAMIC=y`、`CONFIG_SCHED_CLASS_EXT=y`（`sched_ext`）、`CONFIG_SCHED_CORE=y`、`CONFIG_SCHED_CACHE=y`、`CONFIG_SCHED_CLUSTER=y`、`CONFIG_SCHED_MC=y`、`CONFIG_SCHED_SMT=y`、`CONFIG_SCHED_AUTOGROUP=y`、`CONFIG_HZ_250=y` |
| **CPUFreq 与 RCU** | `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`、`CONFIG_RCU_LAZY=y`、`CONFIG_RCU_NOCB_CPU=y` |
| **网络协议栈与队列** | `CONFIG_TCP_CONG_BBR=y`、`CONFIG_DEFAULT_TCP_CONG="bbr"`、`CONFIG_NET_SCH_FQ=y`、`CONFIG_DEFAULT_NET_SCH="fq"`、`CONFIG_NET_SCH_CAKE=m` |
| **内存管理与压缩** | `CONFIG_LRU_GEN=y` & `CONFIG_LRU_GEN_ENABLED=y`（MGLRU）、`CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y`、`CONFIG_THP_SWAP=y`、`CONFIG_ZSWAP=y` & `CONFIG_ZSWAP_DEFAULT_ON=y`、`CONFIG_ZRAM=m` & `CONFIG_ZRAM_DEF_COMP="lzo-rle"`、`CONFIG_KSM=y`、`CONFIG_DAMON=y` |
| **I/O、BPF 与同步原语** | `CONFIG_IOMMU_DEFAULT_DMA_LAZY=y`、`CONFIG_IO_URING=y`、`CONFIG_IO_URING_BPF=y`、`CONFIG_BPF_JIT_ALWAYS_ON=y`、`CONFIG_BPF_LSM=y`、`CONFIG_FUTEX_PI=y`、`CONFIG_FUTEX_PRIVATE_HASH=y`、`CONFIG_NTSYNC=m`、`CONFIG_FUSE_IO_URING=y`、`CONFIG_F2FS_FS_ZSTD=y` |
| **编译与安全加固** | `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y`（`-O2`）、`CONFIG_STACKPROTECTOR_STRONG=y`、`CONFIG_FORTIFY_SOURCE=y`、`CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`、`CONFIG_HARDENED_USERCOPY_DEFAULT_ON=y`、`CONFIG_MODULE_SIG=y` & `CONFIG_MODULE_SIG_ALL=y` |

> [!TIP]
> **关于架构指令集差异**：XanMod 在 `x86_64` 上使用的 `CONFIG_X86_64_VERSION=3`（`-march=x86-64-v3`）属于 x86 独占选项。ARM64 内核通过 `arm64 defconfig` 自带的 LSE 原子指令、PAC、BTI 等运行时指令集替换（alternatives）在现代 ARMv8.2+/v9 核心上发挥性能，同时保持对各类 ARMv8 硬件与云实例的通用兼容。

---

## 构建流水线

工作流文件：[`/.github/workflows/xanmod-arm64.yml`](.github/workflows/xanmod-arm64.yml)

### 触发方式与参数

| 触发事件 | 说明 |
| :--- | :--- |
| **`schedule`** | 每日 `03:37 UTC` 自动运行，检查并构建 `edge`、`main`、`lts` 三个通道 |
| **`workflow_dispatch`** | 手动触发，支持三个输入参数：<br>• `channel`：选择 `all`（默认）、`edge`、`main` 或 `lts`<br>• `enable_btf`：布尔值（默认 `true`），默认采用 `DWARF4 + BTF` 编译以生成 `/sys/kernel/btf/vmlinux`（若需进一步节省运行器磁盘，可手动设为 `false`）<br>• `sync_apt`：布尔值（默认 `false`），在无需重新编译内核时基于现有 Releases 重建并部署 GitHub Pages APT 仓库 |

### 执行阶段

1. **`preflight`（运行于 `ubuntu-latest`）**：
   * 单次分页拉取 GitLab `xanmod/linux` Releases API，匹配非预发布、Tag 符合 `^[0-9]+\.[0-9]+(\.[0-9]+)?-xanmod[0-9]+$` 且存在 SourceForge 对应通道链接的最新版本，提取 `tag` 与 `commit.id`。
   * 检查目标 GitHub Release（`<ver>-arm64-xanmod<N>-<channel>`）是否已完整包含 `linux-image-*.deb`、`linux-headers-*.deb`、`linux-libc-dev_*.deb` 与 `SHA256SUMS`。
   * 仅将待构建通道写入矩阵输出 `matrix`，若全部最新则将 `has_builds` 置为 `false` 直接跳过构建作业。
2. **`build`（矩阵并行，运行于 `ubuntu-24.04-arm`，`fail-fast: false`，超时 360 分钟）**：
   * **Setup**：校验运行器为 `aarch64` / `arm64`；通过 `apt.llvm.org/llvm.sh` 安装 LLVM/Clang 22 与内核构建依赖并建立版本软链（不覆写系统 `/usr/bin/ld`），随后清理 APT 缓存释放磁盘空间。
   * **Config & Build**：浅克隆目标 Tag，校验 `HEAD^{commit}` 一致后提取 7 位短哈希与提交日期并删除 `.git`；执行配置移植与 `olddefconfig` / `syncconfig`；校验 `make -s kernelrelease` 等于 `<ver>-arm64-xanmod<N>`；使用 `ARCH=arm64 LLVM=1 KDEB_PKGVERSION="<kernel_rel>-0~<YYYYMMDD>.g<short7>" KDEB_COMPRESS=xz` 执行 `bindeb-pkg`。
   * **Publish**：校验无 `-dbg`/`-dbgsym` 包、包名/版本号/关键路径完整，解包校验 `/boot/config-<KERNEL_RELEASE>` 与 `.config.final` 字节一致；构建当前通道元包 `linux-xanmod[-edge|-lts]-arm64_${TAG}-0_arm64.deb`；生成 `SHA256SUMS` 与无前导缩进的 `RELEASE.md`；创建或更新 GitHub Release；按 `-arm64(-[^-]+)?-${CHANNEL}$` 精确清理当前通道的历史旧版 Release 与 Tag。
3. **`publish-apt`（运行于 `ubuntu-latest`）**：
   * 检测仓库 Secret `APT_GPG_PRIVATE_KEY`（未配置时输出告警并跳过部署，不影响 Release 发布）。
   * 从各通道最新 Release 拉取镜像、头文件与元包（并校验 `SHA256SUMS`），生成 `pool/main` 与 `dists/stable/main/binary-arm64` 索引，使用 GPG 私钥签发 `Release.gpg` / `InRelease` 并以 `gpgv` 自验后，部署至 GitHub Pages。

---

## 发布产物与安装方式

### Release 资产说明

| 资产 / 内容 | 说明 |
| :--- | :--- |
| `linux-image-<ver>-arm64-xanmod<N>_<pkgver>_arm64.deb` | 内核镜像与模块，包含 `/boot/vmlinuz-*`、`/boot/config-*`、`/boot/System.map-*` 与 `/lib/modules/*` |
| `linux-headers-<ver>-arm64-xanmod<N>_<pkgver>_arm64.deb` | 内核头文件及纯 Clang 构建的主机辅助工具，用于 DKMS 与外部内核模块编译 |
| `linux-xanmod[-edge\|-lts]-arm64_<tag>-0_arm64.deb` | 通道元包（依赖当前最新 `linux-image-*` 与 `linux-headers-*`），供 APT 跟踪通道自动升级 |
| `linux-libc-dev_<pkgver>_arm64.deb` | 用户态 UAPI 开发头文件（一般日常升级内核无需安装此包） |
| `SHA256SUMS` | 上述全部 `.deb` 包的 SHA-256 校验和清单 |
| Release 正文 | 由构建生成的 `RELEASE.md` 渲染，记录架构、通道、Kernel Release、Package Version、元包、上游链接与编译器版本 |

### 方式 A：通过 GitHub Pages APT 源安装并由 `apt` 自动管理（推荐）

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://88860.github.io/XanMod-ARM64-AutoBuild/xanmod-arm64.gpg | sudo tee /etc/apt/keyrings/xanmod-arm64.gpg >/dev/null
sudo chmod 0644 /etc/apt/keyrings/xanmod-arm64.gpg
echo "deb [signed-by=/etc/apt/keyrings/xanmod-arm64.gpg arch=arm64] https://88860.github.io/XanMod-ARM64-AutoBuild stable main" | sudo tee /etc/apt/sources.list.d/xanmod-arm64.list

sudo apt update
# 按需选择一条通道安装：
sudo apt install -y linux-xanmod-arm64       # MAIN
# sudo apt install -y linux-xanmod-edge-arm64  # EDGE
# sudo apt install -y linux-xanmod-lts-arm64   # LTS
sudo update-grub && sudo reboot
```

后续可通过 `sudo apt update && sudo apt upgrade` 自动更新内核。

### 方式 B：手动下载 Release 校验与安装（支持 `edge` / `main` / `lts`）

```bash
# 1. 下载目标 Release 中的 linux-image、linux-headers 与 SHA256SUMS 到临时目录
mkdir -p /tmp/xanmod-arm64 && cd /tmp/xanmod-arm64

# 2. 校验文件完整性（若仅下载了部分 deb，可用 --ignore-missing）
sha256sum --ignore-missing -c SHA256SUMS

# 3. 安装内核镜像与头文件（常规安装与多版本共存建议仅安装 image 和 headers）
sudo apt update
sudo apt install -y ./linux-image-*_arm64.deb ./linux-headers-*_arm64.deb

# 4. 更新引导并重启生效
sudo update-grub
sudo reboot
```

> [!NOTE]
> 多内核共存时不要跨通道混装 `linux-libc-dev`，因为其 Debian 包名固定不含内核版本号，后装会覆盖或提示降级先装版本；这与 XanMod 官方元包仅依赖 `linux-image-*` 和 `linux-headers-*` 一致。

---

## 安装脚本（`xanmod-install.sh`）

[`xanmod-install.sh`](xanmod-install.sh) 为面向 **ARM64** 与 **x86_64** 系统的交互式内核管理脚本，提供版本检测安装、未启用内核与元包清理，以及 GRUB 默认启动项设置功能。脚本运行期间**不会向系统额外安装 `curl`、`jq`、`gnupg` 等辅助软件包**，仅依赖系统内置命令与现有下载工具。

### 执行命令

```bash
curl -fsSL -o /tmp/xanmod-install.sh https://raw.githubusercontent.com/88860/XanMod-ARM64-AutoBuild/main/xanmod-install.sh
sudo bash /tmp/xanmod-install.sh
rm -f /tmp/xanmod-install.sh
```

> 若系统未安装 `curl`，可改用 `wget -qO /tmp/xanmod-install.sh ...` 或 `/usr/lib/apt/apt-helper download-file ... /tmp/xanmod-install.sh` 获取脚本；临时下载目录在脚本退出或重启前自动清理。

### 功能说明

1. **主菜单与无入侵设计**：
   * `1. XanMod 内核安装`：输出当前运行内核、系统架构与指令集等级，检测 **MAIN**、**EDGE**、**LTS** 在线可用版本及本机安装状态，安装或升级后提示按回车重启。
   * `2. 旧内核清理`：保护当前运行内核及其依赖与关联元包（兼容 Debian/Ubuntu、XanMod、Liquorix、Zabbly、Proxmox 及自定义 `.deb` 包），按版本号区分低于与高于当前运行内核的版本；若检测到已安装但尚未重启生效的新内核会给出提示，列出所有未启用项及 `rc` 残留配置的包名与版本供选择卸载，更新并校验 GRUB 后提示按回车重启。
   * `3. 退出`：退出脚本，未安装内核时不对 `/etc/apt` 或系统软件环境作任何改动。
2. **架构适配与零额外依赖机制**：
   * **下载与解析回退**：按优先级复用系统已有的 `curl` / `wget` / `python3` / APT 内置 `apt-helper`；解析 GitHub Releases JSON 时优先复用 `jq` / `python3`，缺失时自动回退至内置 `awk` 流式解析器；导入 `amd64` 仓库公钥时若无 `gpg`，使用 `awk + base64` 直接转换 OpenPGP keyring。
   * **`arm64`**：优先检测 GitHub Pages APT 源（`https://88860.github.io/XanMod-ARM64-AutoBuild`），确认安装后写入 `/etc/apt/sources.list.d/xanmod-arm64.list` 与公钥并安装对应通道元包（`linux-xanmod[-edge|-lts]-arm64`）由 `apt` 托管更新；若 APT 源暂未部署或不可达，则自动回退至 GitHub Releases API 下载 `linux-image-*_arm64.deb` 与 `linux-headers-*_arm64.deb` 并校验 `SHA256SUMS` 后安装。
   * **`amd64`**：结合 `LC_ALL=C` 下动态链接器 `ld-linux-x86-64.so.2 --help` 与 `/proc/cpuinfo` ISA 标志位双重检测 `x86-64-v3` / `x86-64-v2` / `x86-64-v1` 支持等级（官方源仅提供 `x64v1`–`x64v3`，其中 `MAIN`/`EDGE` 仅提供 `x64v2`/`x64v3`，`LTS` 兼容 `x64v1`–`x64v3`，硬件支持 `v4`/AVX-512 时自动匹配 `x64v3`），查询 `http://deb.xanmod.org` 可用版本并在确认安装时写入源配置与公钥。
3. **GRUB 默认启动项配置**：
   * 运行 `update-grub`，从 `/boot/grub/grub.cfg` 提取目标内核的非 `recovery` 菜单 ID（支持 `submenu_id>menuentry_id`）；
   * 配置 `GRUB_DEFAULT=saved` 与 `GRUB_SAVEDEFAULT=false`（若 `/etc/default/grub.d/*.cfg` 存在覆盖项则写入 `/etc/default/grub.d/99-xanmod-default.cfg`），执行 `grub-set-default` 并通过 `grub-editenv` 验证 `saved_entry`。

---

## 安全与校验

* **上游提交核对**：通过 GitLab API 获取目标 Release 对应的完整 Commit SHA，克隆后校验 `git rev-parse HEAD^{commit}` 一致。
* **配置字节比对**：解包 `linux-image` 中的 `/boot/config-<KERNEL_RELEASE>`，与编译期保存的 `.config.final` 执行 `cmp -s` 比对。
* **产物检查**：发布前检查 `Package` 名称、`Version`、`vmlinuz-*`、`/lib/modules/*` 与 `/usr/src/linux-headers-*` 路径完整性，并确认未生成调试包。
* **模块剥离与校验和**：构建默认采用 `DWARF4 + BTF` 生成 `/sys/kernel/btf/vmlinux` 且不输出 `-dbg` 包；Kbuild `builddeb` 在打包时以 `INSTALL_MOD_STRIP=1` 剥离内核模块 DWARF 信息（保留 `.BTF`），并生成 `SHA256SUMS`。

---

## 常见问题与注意事项

1. **`DEBUG_INFO_BTF` 默认值与运行器磁盘空间**  
   为支持 `sched_ext` 调度器与 CO-RE eBPF 工具，`schedule` 与 `workflow_dispatch` 默认设置 `enable_btf: true`（使用 `DWARF4 + BTF` 以兼容 Ubuntu 24.04 的 `pahole`）。由于 `ubuntu-24.04-arm` 运行器可用磁盘约 **14 GB**，工作流会清理未使用的 `lldb`/`clangd`、APT 缓存与 `.git` 目录且不启用 `ccache`。若后续内核版本体积超出磁盘上限，手动触发时可将 `enable_btf` 设为 `false`（切回 `DEBUG_INFO_NONE=y`）。
2. **为什么每次构建后旧的同通道 Release 会消失？**  
   工作流在发布新版后会自动删除同通道下除当前版本之外的历史 Release 及其 Git 标签，以避免仓库释放体积无限膨胀。如需长期留存特定版本，请及时自行下载备份。
3. **自定义内核配置**  
   本仓库提供标准 XanMod 配置的自动化移植与构建；如需针对特定硬件调整选项，建议 Fork 仓库后修改 [`.github/workflows/xanmod-arm64.yml`](.github/workflows/xanmod-arm64.yml) 中的片段生成或 Kconfig 调整步骤。
4. **重启提示**  
   Linux 内核升级必须在安装与 GRUB 配置完成后重启系统才会切换生效，可通过 `uname -r`（预期类似 `7.3.6-arm64-xanmod1`）与 `uname -v` 确认运行版本。

---

## 许可证

本项目基于 MIT 许可证开源；Linux 内核源码遵循 GPL-2.0-only 许可证。
