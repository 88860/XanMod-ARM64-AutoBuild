<div align="center">

# XanMod-ARM64-AutoBuild

**Native ARM64 (aarch64) Build · Automated XanMod Kernel Build Repository**

[![Channels](https://img.shields.io/badge/Channels-EDGE%20%7C%20MAIN%20%7C%20LTS-00b894?style=flat-square)](https://github.com/88860/XanMod-ARM64-AutoBuild/releases)
[![Arch](https://img.shields.io/badge/Arch-ARM64%20aarch64-4eaa25?style=flat-square)](https://www.kernel.org/)
[![Toolchain](https://img.shields.io/badge/Toolchain-LLVM%20%2F%20Clang%2022-0984e3?style=flat-square)](https://llvm.org/)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions%20Native%20ARM64-e84393?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/88860/XanMod-ARM64-AutoBuild/actions/workflows/xanmod-arm64.yml)

[简体中文](README.md) | **English**

[Overview](#overview) · [Features](#features) · [Upstream-Aligned Naming](#upstream-aligned-naming) · [x86_64 Config Porting](#x86_64-config-porting) · [Build Pipeline](#build-pipeline) · [Release Artifacts & Manual Install](#release-artifacts--manual-install) · [Install Script](#install-script-xanmod-installsh) · [Verification](#verification) · [Notes & FAQ](#notes--faq)

</div>

---

## Overview

`XanMod-ARM64-AutoBuild` automates XanMod kernel builds and releases for **Debian / Ubuntu ARM64 (`aarch64`)**. While official XanMod packages target `amd64` (`x64v1` / `x64v2` / `x64v3`), this repository uses GitHub Actions ARM64 runners (`ubuntu-24.04-arm`) and **LLVM / Clang 22** to track [GitLab XanMod Linux](https://gitlab.com/xanmod/linux) across **EDGE**, **MAIN**, and **LTS**, port XanMod patches and `x86_64` config options to ARM64, and publish standard `.deb` packages to GitHub Releases.

> [!IMPORTANT]
> **Build environment**: GitHub Actions `ubuntu-24.04-arm` (`aarch64`) native runner.  
> **Target host**: Debian / Ubuntu systems on `arm64` ([`xanmod-install.sh`](xanmod-install.sh) also supports the official `amd64` APT repository).

---

## Features

* **Multi-Channel Matrix with Isolation**: [`.github/workflows/xanmod-arm64.yml`](.github/workflows/xanmod-arm64.yml) manages `edge`, `main`, and `lts` via a dynamic matrix with `fail-fast: false`, so failures in one channel do not block others.
* **Upstream-Aligned Naming**: `uname -r`, `.deb` `Package` names, `KDEB_PKGVERSION` (commit date and 7-char short SHA), and artifact filenames follow upstream `.gitlab-ci.yml` conventions, replacing `x64v*` / `amd64` with `arm64`.
* **Architecture-Scoped Kconfig Porting**: Starts from `arm64 defconfig` and parses Kconfig symbols plus `choice ... endchoice` blocks to apply XanMod scheduler, preemption, network, memory, I/O, and hardening options while keeping ARM64 boot drivers intact.
* **Native LLVM/Clang Build**: Compiles with `ARCH=arm64 LLVM=1` (`clang-22`, `ld.lld-22`, `llvm-ar-22`, etc.) without `CROSS_COMPILE`, preventing host tools in `linux-headers` from being built with GCC.
* **Post-Build Verification**: Verifies upstream Commit SHA pinning, byte-level `.config.final` parity inside `linux-image`, `dpkg-deb` contents, and `SHA256SUMS`.

---

## Upstream-Aligned Naming

Following upstream `xanmod/linux` (`.gitlab-ci.yml`, `scripts/setlocalversion`, and `scripts/package/mkdebian`), the architecture identifier changes from `x64v*` / `amd64` to `arm64` while keeping the rest of the naming scheme identical:

| Component | Official XanMod (`x64v3` example) | This Project (`arm64`) |
| :--- | :--- | :--- |
| **`CONFIG_LOCALVERSION`** | `"-x64v3"` | `"-arm64"` |
| **`localversion` file** | `"-xanmod1"` (from upstream tree) | `"-xanmod1"` (preserved as `-${TAG#*-}`) |
| **`KERNELRELEASE` / `uname -r`** | `7.3.6-x64v3-xanmod1` | `7.3.6-arm64-xanmod1` |
| **`KDEB_PKGVERSION` (`Version`)** | `7.3.6-x64v3-xanmod1-0~20261123.g6b041b1` | `7.3.6-arm64-xanmod1-0~20261123.g6b041b1` |
| **Image `Package`** | `linux-image-7.3.6-x64v3-xanmod1` | `linux-image-7.3.6-arm64-xanmod1` |
| **Headers `Package`** | `linux-headers-7.3.6-x64v3-xanmod1` | `linux-headers-7.3.6-arm64-xanmod1` |
| **`.deb` Filename** | `linux-image-7.3.6-x64v3-xanmod1_7.3.6-x64v3-xanmod1-0~20261123.g6b041b1_amd64.deb` | `linux-image-7.3.6-arm64-xanmod1_7.3.6-arm64-xanmod1-0~20261123.g6b041b1_arm64.deb` |
| **Channel Isolation** | APT metapackages (`linux-xanmod[-edge\|-lts]-x64v3`) & SourceForge dirs | Channel suffix on GitHub Release Tag (`<KERNELRELEASE>-<channel>`) |

> [!NOTE]
> **Channel Isolation Note**: Official XanMod kernel versions and `.deb` package names do not contain `main`/`edge`/`lts`. This repo appends `-${CHANNEL}` only to the **GitHub Release Tag** (e.g., `7.3.6-arm64-xanmod1-main`, `7.3.1-arm64-xanmod1-edge`, `6.18.65-arm64-xanmod1-lts`) so all three channels coexist in one repository without colliding or purging each other. If `edge` and `main` resolve to the same upstream tag, both produce the identical kernel package.

---

## x86_64 Config Porting

XanMod behavior derives from both its **kernel patchset** (BBRv3, `PREEMPT_LAZY`, `sched_ext`, futex/`ntsync`) and **`CONFIGS/x86_64/config`**. The workflow applies a four-step porting process:

### 1. Porting Pipeline

1. **ARM64 Baseline**: Starts with `make ARCH=arm64 LLVM=1 defconfig` so Device Tree (`CONFIG_OF`), serial consoles (e.g., PL011), ACPI/EFI boot, GIC interrupt controllers, and runtime alternatives patching (`LSE`/`PAC`/`BTI`) remain intact.
2. **Arch-Scoped Symbol Filtering**: Scans `Kconfig*` while pruning non-`arm64` `arch/*` directories to exclude x86-only symbols; skips `CONFIG_NR_CPUS=8192` (above `arch/arm64/Kconfig`'s `2..4096` limit) to retain ARM64's `512` default.
3. **`choice ... endchoice` Resolution**:
   * Copying every `# CONFIG_* is not set` entry verbatim from `x86_64` would disable `CONFIG_OF` and break ARM64 boot;
   * An inline Python Kconfig parser detects every `choice ... endchoice` group where XanMod picks an ARM64-valid `=y` option and emits the disabled sibling symbols (overriding ARM64 defaults such as `CONFIG_PREEMPT`, `CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`, `CONFIG_IOMMU_DEFAULT_DMA_STRICT`, `CONFIG_DEFAULT_CUBIC`, `CONFIG_DEFAULT_PFIFO_FAST`, etc.), alongside verified disable flags (`DEBUG_PREEMPT`, `PREEMPT_TRACER`, `RCU_LAZY_DEFAULT_OFF`, `WERROR`, `OBJTOOL_WERROR`).
4. **Built-in Preservation & Summary Check**:
   * Merges via `./scripts/kconfig/merge_config.sh -m -y .config xanmod.arm64.fragment` (`-y` prevents `arm64 defconfig` built-in `=y` drivers such as `CONFIG_KVM`, `CONFIG_VIRTIO_NET`, `CONFIG_VIRTIO_MMIO`, and `CONFIG_VIRTIO_BALLOON` from reverting to `=m`);
   * After `olddefconfig` and `syncconfig`, prints a verification table to the GitHub Actions Job Summary and emits `::warning::` if any requested option was dropped by Kconfig dependencies.

### 2. Ported Options Summary

| Area | Key Options Ported (when present in upstream release) |
| :--- | :--- |
| **Scheduling & Preemption** | `CONFIG_PREEMPT_LAZY=y`, `CONFIG_PREEMPT_DYNAMIC=y`, `CONFIG_SCHED_CLASS_EXT=y` (`sched_ext`), `CONFIG_SCHED_CORE=y`, `CONFIG_SCHED_CACHE=y`, `CONFIG_SCHED_CLUSTER=y`, `CONFIG_SCHED_MC=y`, `CONFIG_SCHED_SMT=y`, `CONFIG_SCHED_AUTOGROUP=y`, `CONFIG_HZ_250=y` |
| **CPUFreq & RCU** | `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`, `CONFIG_RCU_LAZY=y`, `CONFIG_RCU_NOCB_CPU=y` |
| **Networking & Qdisc** | `CONFIG_TCP_CONG_BBR=y`, `CONFIG_DEFAULT_TCP_CONG="bbr"`, `CONFIG_NET_SCH_FQ=y`, `CONFIG_DEFAULT_NET_SCH="fq"`, `CONFIG_NET_SCH_CAKE=m` |
| **Memory & Compression** | `CONFIG_LRU_GEN=y` & `CONFIG_LRU_GEN_ENABLED=y` (MGLRU), `CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y`, `CONFIG_THP_SWAP=y`, `CONFIG_ZSWAP=y` & `CONFIG_ZSWAP_DEFAULT_ON=y`, `CONFIG_ZRAM=m` & `CONFIG_ZRAM_DEF_COMP="lzo-rle"`, `CONFIG_KSM=y`, `CONFIG_DAMON=y` |
| **I/O, BPF & Sync** | `CONFIG_IOMMU_DEFAULT_DMA_LAZY=y`, `CONFIG_IO_URING=y`, `CONFIG_IO_URING_BPF=y`, `CONFIG_BPF_JIT_ALWAYS_ON=y`, `CONFIG_BPF_LSM=y`, `CONFIG_FUTEX_PI=y`, `CONFIG_FUTEX_PRIVATE_HASH=y`, `CONFIG_NTSYNC=m`, `CONFIG_FUSE_IO_URING=y`, `CONFIG_F2FS_FS_ZSTD=y` |
| **Compiler & Hardening** | `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y` (`-O2`), `CONFIG_STACKPROTECTOR_STRONG=y`, `CONFIG_FORTIFY_SOURCE=y`, `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`, `CONFIG_HARDENED_USERCOPY_DEFAULT_ON=y`, `CONFIG_MODULE_SIG=y` & `CONFIG_MODULE_SIG_ALL=y` |

> [!TIP]
> **Architecture ISA Note**: `CONFIG_X86_64_VERSION=3` (`-march=x86-64-v3`) is x86-specific. On ARM64, the kernel relies on runtime alternatives patching (`CONFIG_ARM64_LSE_ATOMICS`, `PAC`, `BTI`, etc. enabled via `arm64 defconfig`) to accelerate newer ARMv8.2+/v9 CPUs while remaining bootable across standard ARM64 servers and SBCs.

---

## Build Pipeline

Workflow file: [`/.github/workflows/xanmod-arm64.yml`](.github/workflows/xanmod-arm64.yml)

### Triggers & Inputs

| Trigger | Behavior |
| :--- | :--- |
| **`schedule`** | Runs daily at `03:37 UTC`, checking and building `edge`, `main`, and `lts` |
| **`workflow_dispatch`** | Manual trigger with two inputs:<br>• `channel`: `all` (default), `edge`, `main`, or `lts`<br>• `enable_btf`: boolean (default `true`); builds with `DWARF4 + BTF` by default to emit `/sys/kernel/btf/vmlinux` (set to `false` manually if runner disk space is constrained) |

### Stages

1. **`preflight` (`ubuntu-latest`)**:
   * Scans GitLab `xanmod/linux` Releases API in a single pass for non-upcoming tags matching `^[0-9]+\.[0-9]+(\.[0-9]+)?-xanmod[0-9]+$` with SourceForge links for each target channel, extracting `tag` and `commit.id`.
   * Checks whether the corresponding GitHub Release (`<ver>-arm64-xanmod<N>-<channel>`) already contains `linux-image-*.deb`, `linux-headers-*.deb`, `linux-libc-dev_*.deb`, and `SHA256SUMS`.
   * Outputs `matrix` containing only channels requiring builds; when all channels are up to date, `has_builds=false` skips the `build` job without empty-matrix errors.
2. **`build` (matrix on `ubuntu-24.04-arm`, `fail-fast: false`, 360 min timeout)**:
   * **Setup**: Asserts `aarch64` / `arm64`; installs LLVM/Clang 22 via `apt.llvm.org/llvm.sh` and build dependencies, symlinks LLVM tools without replacing system `/usr/bin/ld`, and clears APT lists/cache to preserve disk space.
   * **Config & Build**: Shallow-clones the tag, verifies `HEAD^{commit}`, records 7-char commit SHA & commit date, removes `.git`, applies optimization porting + `olddefconfig` / `syncconfig`, validates `make -s kernelrelease`, and packages via `ARCH=arm64 LLVM=1 KDEB_PKGVERSION="<kernel_rel>-0~<YYYYMMDD>.g<short7>" KDEB_COMPRESS=xz bindeb-pkg`.
   * **Publish**: Ensures no `-dbg`/`-dbgsym` packages exist, verifies package names, versions, `/boot/vmlinuz-*`, `/lib/modules/*`, `/usr/src/linux-headers-*`, and byte-compares extracted `boot/config-*` against `.config.final`; writes `SHA256SUMS` and `RELEASE.md`, creates/updates the GitHub Release, and deletes older Releases/Tags matching `-arm64(-[^-]+)?-${CHANNEL}$` for the same channel only.

---

## Release Artifacts & Manual Install

### Release Assets

| Asset / Content | Description |
| :--- | :--- |
| `linux-image-<ver>-arm64-xanmod<N>_<pkgver>_arm64.deb` | Kernel image and stripped modules (`/boot/vmlinuz-*`, `/boot/config-*`, `/boot/System.map-*`, `/lib/modules/*`) |
| `linux-headers-<ver>-arm64-xanmod<N>_<pkgver>_arm64.deb` | Kernel headers and pure Clang-built host scripts for DKMS / out-of-tree modules |
| `linux-libc-dev_<pkgver>_arm64.deb` | Userspace kernel UAPI headers (optional; not required for normal kernel upgrades) |
| `SHA256SUMS` | SHA-256 checksums for all `.deb` artifacts |
| Release Notes | Rendered from `RELEASE.md` (architecture, channel, Kernel Release, Package Version, upstream link, Clang version) |

### Manual Download, Verification & Install (`edge` / `main` / `lts`)

```bash
# 1. Download linux-image, linux-headers, and SHA256SUMS from the target Release
mkdir -p /tmp/xanmod-arm64 && cd /tmp/xanmod-arm64

# 2. Verify integrity (--ignore-missing works if you skipped linux-libc-dev)
sha256sum --ignore-missing -c SHA256SUMS

# 3. Install kernel image and headers
sudo apt update
sudo apt install -y ./linux-image-*_arm64.deb ./linux-headers-*_arm64.deb

# 4. Update GRUB and reboot
sudo update-grub
sudo reboot
```

> [!NOTE]
> When keeping multiple kernel versions installed side-by-side, avoid mixing `linux-libc-dev` across channels because its Debian package name does not embed a version suffix (installing another version replaces or downgrades the previous `linux-libc-dev`).

---

## Install Script (`xanmod-install.sh`)

[`xanmod-install.sh`](xanmod-install.sh) is an interactive Bash kernel management script for **ARM64** and **x86_64**, providing version detection and installation, inactive kernel and metapackage cleanup, and GRUB default entry configuration. It runs **without installing `curl`, `jq`, `gnupg`, or any extra packages** onto the host system.

### Usage

```bash
curl -fsSL -o /tmp/xanmod-install.sh https://raw.githubusercontent.com/88860/XanMod-ARM64-AutoBuild/main/xanmod-install.sh
sudo bash /tmp/xanmod-install.sh
rm -f /tmp/xanmod-install.sh
```

> If `curl` is absent on a minimal system, fetch the script with `wget -qO /tmp/xanmod-install.sh ...` or `/usr/lib/apt/apt-helper download-file ... /tmp/xanmod-install.sh`; temporary download directories are removed automatically before exit or reboot.

### Features

1. **Main Menu & Non-Intrusive Execution**:
   * `1. XanMod 内核安装` (Install / Upgrade): Displays running kernel, system architecture, and CPU tier; checks available **MAIN**, **EDGE**, and **LTS** versions against installed packages and prompts Enter to reboot after installation.
   * `2. 旧内核清理` (Old Kernel Cleanup): Protects the running kernel along with its dependencies and linked metapackages (covering Debian/Ubuntu, XanMod, Liquorix, Zabbly, Proxmox, and custom `.deb` kernels); compares versions to distinguish older kernels from installed newer kernels awaiting reboot (alerting when a reboot is pending), lists all inactive packages and residual `rc` configs with their versions, updates/verifies GRUB, and prompts Enter to reboot.
   * `3. 退出` (Exit): Exits without altering `/etc/apt` or system packages if no install or cleanup was run.
2. **Architecture Handling & Built-in Fallbacks**:
   * **Zero-package fallbacks**: Reuses preinstalled `curl`, `wget`, `python3`, or APT's `/usr/lib/apt/apt-helper` for HTTP downloads; parses GitHub Releases JSON via `jq`, `python3`, or a built-in `awk` streaming parser; converts ASCII-armored `amd64` GPG keys via `awk + base64` when `gpg` is absent.
   * **`arm64`**: Queries GitHub Releases API across **MAIN** / **EDGE** / **LTS**, downloads `linux-image-*_arm64.deb` and `linux-headers-*_arm64.deb`, verifies them against `SHA256SUMS` when provided, and installs via APT.
   * **`amd64`**: Probes `x86-64-v3` / `x86-64-v2` / `x86-64-v1` using both `LC_ALL=C ld-linux-x86-64.so.2 --help` and `/proc/cpuinfo` ISA flags (official XanMod provides `x64v1`–`x64v3` only; `MAIN`/`EDGE` support `x64v2`/`x64v3`, `LTS` supports `x64v1`–`x64v3`, and `v4`/AVX-512 CPUs map to `x64v3`), checks `http://deb.xanmod.org`, and configures the APT source and keyring only after install confirmation.
3. **GRUB Configuration**:
   * Runs `update-grub` and extracts the non-recovery menu ID for the installed kernel from `/boot/grub/grub.cfg` (supports `submenu_id>menuentry_id` nesting);
   * Sets `GRUB_DEFAULT=saved` and `GRUB_SAVEDEFAULT=false` (writing `/etc/default/grub.d/99-xanmod-default.cfg` if any `grub.d/*.cfg` overrides them), executes `grub-set-default`, and verifies `saved_entry` via `grub-editenv`.

---

## Verification

* **Upstream Commit Pinning**: Cloned source commit is verified against GitLab's `commit.id` via `git rev-parse HEAD^{commit}`.
* **Byte-Level Config Check**: Extracted `boot/config-<KERNEL_RELEASE>` inside `linux-image` is compared against `.config.final` via `cmp -s`.
* **Package Content Check**: Validates package names, versions, `/boot/vmlinuz-*`, `/lib/modules/*`, `/usr/src/linux-headers-*`, and ensures no debug packages are produced.
* **Stripped Modules & Checksums**: Builds enable `DWARF4 + BTF` by default for `/sys/kernel/btf/vmlinux` without emitting `-dbg` packages; Kbuild `builddeb` strips module DWARF debug info (`INSTALL_MOD_STRIP=1`, keeping `.BTF`), and `SHA256SUMS` accompanies each release.

---

## Notes & FAQ

1. **Default `DEBUG_INFO_BTF` & runner disk usage**  
   Scheduled and manual builds default to `enable_btf: true` (`DWARF4 + BTF` for Ubuntu 24.04 `pahole` compatibility) to support `sched_ext` schedulers and CO-RE eBPF tools. Because `ubuntu-24.04-arm` runners provide ~**14 GB** of usable disk space, the workflow removes unused `lldb`/`clangd`, APT caches, and `.git`, and omits `ccache`. If a future release exceeds runner disk limits, trigger `workflow_dispatch` with `enable_btf: false` (`DEBUG_INFO_NONE=y`).
2. **Why are older releases removed automatically?**  
   Each channel keeps only its latest Release and Git tag to prevent unbounded storage growth. Back up older `.deb` packages locally if you need historical builds.
3. **Custom kernel configs**  
   This repository provides automated builds of the standard ported XanMod configuration. To customize options for specific hardware, fork the repository and adjust the fragment/config steps in [`.github/workflows/xanmod-arm64.yml`](.github/workflows/xanmod-arm64.yml).
4. **Reboot required**  
   Always reboot after installation to load the new kernel, then verify with `uname -r` (e.g. `7.3.6-arm64-xanmod1`) and `uname -v`.

---

## License

This repository is licensed under the MIT License; the Linux kernel source is licensed under GPL-2.0-only.
