<div align="center">


# XanMod-ARM64-AutoBuild


**ARM64 原生构建 · XanMod 内核自动化发布平台**


[![Channel](https://img.shields.io/badge/Channel-EDGE%20%7C%20MAIN%20%7C%20LTS-00b894?style=flat-square)](https://github.com/88860/XanMod-ARM64-AutoBuild)
[![Arch](https://img.shields.io/badge/Arch-ARM64%20aarch64-4eaa25?style=flat-square)](https://www.kernel.org/)
[![Toolchain](https://img.shields.io/badge/Toolchain-Clang%2022-0984e3?style=flat-square)](https://llvm.org/)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-e84393?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/88860/XanMod-ARM64-AutoBuild/actions)


[简体中文] | [English](README_EN.md)


[概览](#概览) · [构建流水线](#构建流水线) · [发布产物](#发布产物) · [安装脚本](#安装脚本) · [架构支持](#架构支持) · [安全与校验](#安全与校验) · [注意事项](#注意事项)


</div>


---


## 概览


`XanMod-ARM64-AutoBuild` 是一个基于 GitHub Actions 的 ARM64 (aarch64) XanMod 内核自动化构建与发布平台。平台每日自动追踪 XanMod 上游 EDGE / MAIN / LTS 三个发布通道，在原生 ARM64 运行器上使用 LLVM/Clang 22 工具链完成全量编译，输出标准 Debian 二进制包并发布到 GitHub Releases。随附的 `xanmod-main-install.sh` 提供一键安装、GRUB 启动项切换及内核升级能力。


> [!IMPORTANT]
> **构建端要求**：原生 ARM64 (aarch64) 硬件，不支持交叉编译。  
> **安装端要求**：Debian / Ubuntu 系统，ARM64 架构。


---


## 构建流水线


### 三通道并行构建

平台维护三个独立的 GitHub Actions 工作流，分别对应 XanMod 上游的 **EDGE**、**MAIN**、**LTS** 通道。每条流水线独立运行，互不阻塞：

| 工作流 | 上游通道 | 触发方式 | 定时 (UTC) |
| :--- | :--- | :--- | :--- |
| `xanmod-arm64-edge.yml` | EDGE | `workflow_dispatch` + `schedule` | 每日 03:37 |
| `xanmod-arm64-main.yml` | MAIN | `workflow_dispatch` + `schedule` | 每日 03:37 |
| `xanmod-arm64-lts.yml` | LTS | `workflow_dispatch` + `schedule` | 每日 03:37 |


### 构建阶段拆解

每条流水线分为三个顺序执行的阶段：

**1. Preflight（预检）**
- 从 GitLab XanMod Linux 仓库拉取最新 Release 列表
- 筛选出符合通道版本号格式（`[0-9]+.[0-9]+.[0-9]+-xanmod[0-9]+`）且包含 SourceForge 资产链接的稳定版本
- 提取对应 Git Commit ID 作为构建基准
- 检查 GitHub Release 是否已存在并包含完整 deb 资产（`linux-image`、`linux-headers`、`linux-libc-dev`、`SHA256SUMS`），若齐全则跳过本次构建

**2. Build（原生编译）**
- 运行器：`ubuntu-24.04-arm`（原生 aarch64，非交叉编译）
- 工具链：LLVM/Clang 22（`clang`、`lld`、`llvm-ar` 等），启用 `ccache` 加速二次构建
- 内核源码：从 `gitlab.com/xanmod/linux` 按指定 Tag 克隆，并校验 Commit ID 一致性
- 配置合并：将 XanMod x86_64 基础配置与 ARM64 Kconfig 符号集合取交集，生成 `xanmod.arm64.fragment`，并通过 `merge_config.sh` 合并进内核 `.config`
- 关键配置调整：`CONFIG_KVM=y`，禁用 `DEBUG_INFO*` 系列，启用 `DEBUG_INFO_NONE`，`LOCALVERSION_AUTO` 禁用
- 编译参数：`ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu-`，使用 `ccache clang --target=aarch64-linux-gnu`，链接器为 `ld.lld`
- 输出验证：`make kernelrelease` 必须等于 `<TAG>-arm64-<CHANNEL>`，确保版本字符串一致
- 打包：`bindeb-pkg` 目标，启用 `skipdbg=true`、`INSTALL_MOD_STRIP=1`、`KDEB_COMPRESS=gzip`

**3. Publish（发布）**
- 资产校验：通过 `dpkg-deb` 检查 `linux-image` 包包含 `/boot/vmlinuz-` 和 `/lib/modules/`，`linux-headers` 包包含 `/usr/src/linux-headers-`
- 配置比对：提取 deb 内的 `boot/config-<version>` 与构建时的 `.config.final` 做二进制比对 (`cmp`)，确保运行时配置与构建配置完全一致
- 签名：对所有 `.deb` 生成 `SHA256SUMS`
- 发布：通过 `gh release` 创建或覆盖 GitHub Release，附带 `RELEASE.md` 说明（架构、通道、上游链接、编译器版本）
- 清理：删除同通道下除当前版本外的旧 Release 及其 Git 标签


---


## 发布产物

每次成功构建均产出以下资产，上传至对应通道的 GitHub Release：

| 产物 | 说明 |
| :--- | :--- |
| `linux-image-*-arm64-<channel>.deb` | 内核镜像与模块，包含 `/boot/vmlinuz-` 与 `/lib/modules/` |
| `linux-headers-*-arm64-<channel>.deb` | 内核头文件，用于编译外部模块 |
| `linux-libc-dev_*.deb` | 内核 libc 开发头文件 |
| `SHA256SUMS` | 所有 `.deb` 的 SHA-256 校验和 |
| `RELEASE.md` | 发布说明（架构、通道、上游 Tag、编译器版本） |


---


## 安装脚本（xanmod-main-install.sh）

随附安装脚本用于在目标机器上下载并安装最新的 ARM64 MAIN 内核。

### 功能流程

1. **依赖预检**：安装 `wget`、`curl`、`gpg`、`ca-certificates`、`jq`、`grub-common`、`grub2-common`
2. **架构识别**：通过 `dpkg --print-architecture` 或 `uname -m` 判断 `amd64` / `arm64`
3. **版本比对**：对比当前已安装内核版本与 GitHub Release 最新 Tag
4. **交互确认**：
   - 未安装：询问是否安装
   - 已是最新且正在运行：退出
   - 已是最新但未启用：询问是否配置 GRUB
   - 发现新版本：询问是否升级
5. **包下载**：解析 GitHub Release 资产列表，筛选 `linux-image-*_arm64.deb`、`linux-headers-*_arm64.deb`、`linux-libc-dev*.deb`
6. **本地安装**：`apt install` 下载的 `.deb` 包
7. **GRUB 配置**：
   - 从 `grub.cfg` 提取新内核的启动项 ID（`sub_id > m_id` 格式）
   - 写入 `GRUB_DEFAULT=saved` 和 `GRUB_SAVEDEFAULT=false`
   - 执行 `grub-set-default` 并通过 `grub-editenv` 验证 `saved_entry`
8. **系统重启**：提示用户立即重启以加载新内核


### 使用示例

```bash
# 下载并执行安装脚本
curl -sSL -o /tmp/xanmod-install.sh https://raw.githubusercontent.com/88860/XanMod-ARM64-AutoBuild/main/xanmod-main-install.sh
bash /tmp/xanmod-install.sh
rm -f /tmp/xanmod-install.sh
```

> 安装完成后必须重启系统，新内核才会生效。


---


## 架构支持矩阵


| 架构 | 安装来源 | 支持状态 | 备注 |
| :--- | :--- | :--- | :--- |
| **ARM64 (aarch64)** | 本仓库 GitHub Release `.deb` | ✅ 原生支持 | 由 GitHub Actions 原生编译 |
| **amd64 (x64v2 / x64v3)** | 官方 Debian 源 (`deb.xanmod.org`) | ✅ 脚本兼容 | 脚本内置 x86-64-v2/v3 检测逻辑 |
| 其他架构 | — | ❌ 不支持 | — |


---


## 安全与校验

* **上游提交锁定**：构建前通过 `git rev-parse HEAD^{commit}` 校验 XanMod 上游 Commit ID，确保编译的是预期提交而非任意分支头。
* **内核配置比对**：构建完成后，从生成的 `linux-image` deb 中提取 `/boot/config-<version>`，与编译时的 `.config.final` 做 `cmp` 二进制比对，任何不一致将导致构建失败。
* **deb 结构校验**：使用 `dpkg-deb --contents` 验证内核镜像包包含启动镜像与模块目录，头文件包包含内核头路径，缺失任一关键路径即中止发布。
* **调试符号剥离**：编译时启用 `skipdbg=true` 与 `INSTALL_MOD_STRIP=1`，去除不必要的调试信息，减小包体积并降低内核符号泄露风险。
* **资产完整性**：所有发布 `.deb` 附带 `SHA256SUMS`，安装脚本可据此校验下载文件完整性（若需手动校验）。


---


## 注意事项

1. **构建端硬件限制**：CI 使用 GitHub Actions `ubuntu-24.04-arm` 原生 ARM64 运行器，不支持在 x86 架构上交叉编译 ARM64 内核。
2. **GRUB 配置风险**：安装脚本会修改 `/etc/default/grub` 及 `/boot/grub/grub.cfg`，并通过 `grub-set-default` 切换默认启动项。安装后务必重启系统，否则新内核不会生效。
3. **网络依赖**：ARM64 安装脚本依赖访问 `github.com` 及 `api.github.com` 获取 Release 信息和下载 `.deb` 包。
4. **旧版本清理**：CI 会自动删除同通道下的旧 Release 和标签，仅保留最新版本。如需归档旧版本，请在自动清理前自行下载备份。
5. **无内核定制服务**：本项目仅提供标准配置的自动构建，不提供内核 `.config` 定制。如需修改内核选项，请在 `xanmod.arm64.fragment` 生成逻辑或工作流中调整 Kconfig 合并步骤。


---


## 许可证

本项目基于 MIT 许可证开源。
