<div align="center">


# XanMod-ARM64-AutoBuild


**ARM64 Native Build · XanMod Kernel Automated Release Platform**


[![Channel](https://img.shields.io/badge/Channel-EDGE%20%7C%20MAIN%20%7C%20LTS-00b894?style=flat-square)](https://github.com/88860/XanMod-ARM64-AutoBuild)
[![Arch](https://img.shields.io/badge/Arch-ARM64%20aarch64-4eaa25?style=flat-square)](https://www.kernel.org/)
[![Toolchain](https://img.shields.io/badge/Toolchain-Clang%2022-0984e3?style=flat-square)](https://llvm.org/)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-e84393?style=flat-square&logo=github-actions&logoColor=white)](https://github.com/88860/XanMod-ARM64-AutoBuild/actions)


[简体中文](README.md) | **English**


[Overview](#overview) · [Build Pipeline](#build-pipeline) · [Release Artifacts](#release-artifacts) · [Installation Script](#installation-script) · [Architecture Support](#architecture-support) · [Security & Integrity](#security--integrity) · [Notes](#notes)


</div>


---


## Overview


`XanMod-ARM64-AutoBuild` is a GitHub Actions–based platform for fully automated building and releasing of **native ARM64 (aarch64)** XanMod kernels. It tracks XanMod upstream EDGE / MAIN / LTS release channels daily, compiles natively on ARM64 hardware using the **LLVM/Clang 22** toolchain, publishes standard Debian binary packages (`.deb`) to GitHub Releases, and ships `xanmod-main-install.sh` for one-click installation, GRUB boot entry switching, and kernel upgrades.


> [!IMPORTANT]
> **Build host requirements**: Native **ARM64 (aarch64)** hardware. Cross-compilation is not supported.  
> **Install host requirements**: Debian / Ubuntu systems, ARM64 architecture.


---


## Build Pipeline


### Unified Multi-Channel Build

The platform maintains a single unified GitHub Actions workflow (`xanmod-arm64.yml`) using a dynamic matrix to track and build XanMod upstream's **EDGE**, **MAIN**, and **LTS** channels independently (`fail-fast: false`):

| Workflow | Channels | Trigger | Schedule (UTC) |
| :--- | :--- | :--- | :--- |
| `xanmod-arm64.yml` | `edge` / `main` / `lts` | `workflow_dispatch` (`all` or single channel, `enable_btf`) + `schedule` | Daily 03:37 |


### Stage Breakdown

The pipeline executes preflight resolution followed by a parallel matrix build:

**1. Preflight**
- Polls GitLab `xanmod/linux` releases in a single pass for the latest stable tags matching `[0-9]+.[0-9]+(.[0-9]+)?-xanmod[0-9]+` with SourceForge links for each target channel.
- Extracts the corresponding Git commit ID as the build baseline.
- Checks whether the channel's GitHub Release already exists with all required deb assets (`linux-image`, `linux-headers`, `linux-libc-dev`, `SHA256SUMS`), and includes only channels needing a build in the matrix.

**2. Build (Native Compilation)**
- Runner: `ubuntu-24.04-arm` (native aarch64, no cross-compilation).
- Toolchain: LLVM/Clang 22 (`clang`, `lld`, `llvm-ar`, etc.), built natively without `CROSS_COMPILE` so `linux-headers` host tools stay purely Clang-built.
- Kernel source: shallow-cloned from `gitlab.com/xanmod/linux` at the specified tag; commit ID is verified against the expected baseline.
- Configuration port: intersects XanMod `CONFIGS/x86_64/config` with generic + `arm64` Kconfig symbols (plus safe optimization-choice disables), merged via `merge_config.sh -m -y` to preserve ARM64 built-in `=y` drivers.
- Key config adjustments: upstream `localversion` preserved with `CONFIG_LOCALVERSION="-arm64"`; `LOCALVERSION_AUTO` disabled; `DEBUG_INFO_NONE` enabled by default (optional `enable_btf` dispatch input enables `DWARF4 + BTF`).
- Build flags: `ARCH=arm64 LLVM=1`.
- Output validation: `make kernelrelease` must equal `<kernel_version>-arm64-<xanmod_suffix>` (fully synced with upstream except architecture, e.g., `7.3.6-arm64-xanmod1`), and reports applied XanMod optimizations to the Job Summary.
- Packaging: `bindeb-pkg` target with `KDEB_PKGVERSION="<kernelrelease>-0~<YYYYMMDD>.g<7-char-SHA>"` and `KDEB_COMPRESS=xz`.

**3. Publish**
- Asset validation: `dpkg-deb` checks that `linux-image` contains `/boot/vmlinuz-` and `/lib/modules/`, and `linux-headers` contains `/usr/src/linux-headers-`.
- Config comparison: extracts `boot/config-<version>` from the built image and byte-compares (`cmp`) it against `.config.final`; any mismatch aborts the publish.
- Signing: generates `SHA256SUMS` for all `.deb` artifacts.
- Release: creates or overwrites the GitHub Release via `gh release` (tagged `<kernelrelease>-<channel>` to isolate the three channels), attaching `RELEASE.md` (architecture, channel, kernel release, package version, upstream link, compiler version).
- Cleanup: deletes previous releases and tags for the same channel, retaining only the latest.


---


## Release Artifacts

Each successful build publishes the following assets to the corresponding channel's GitHub Release:

| Artifact | Description |
| :--- | :--- |
| `linux-image-<ver>-arm64-xanmod<N>_..._arm64.deb` | Kernel image and modules, including `/boot/vmlinuz-` and `/lib/modules/` |
| `linux-headers-<ver>-arm64-xanmod<N>_..._arm64.deb` | Kernel headers for out-of-tree module compilation |
| `linux-libc-dev_<ver>-arm64-xanmod<N>-..._arm64.deb` | Kernel libc development headers |
| `SHA256SUMS` | SHA-256 checksums for all `.deb` packages |
| `RELEASE.md` | Release notes (architecture, channel, upstream tag, compiler version) |


---


## Installation Script (`xanmod-main-install.sh`)

The bundled script downloads and installs the latest ARM64 MAIN kernel on the target machine.

### Workflow

1. **Dependency pre-check**: installs `wget`, `curl`, `gpg`, `ca-certificates`, `jq`, `grub-common`, `grub2-common`.
2. **Architecture detection**: uses `dpkg --print-architecture` or `uname -m` to determine `amd64` / `arm64`.
3. **Version comparison**: compares the currently installed kernel against the latest GitHub Release tag.
4. **Interactive confirmation**:
   - Not installed: prompts to install.
   - Already latest and running: exits.
   - Already latest but not booted: prompts to configure GRUB.
   - New version available: prompts to upgrade.
5. **Package download**: parses the GitHub Release asset list and selects `linux-image-*_arm64.deb`, `linux-headers-*_arm64.deb`, `linux-libc-dev*.deb`.
6. **Local installation**: installs downloaded `.deb` packages via `apt`.
7. **GRUB configuration**:
   - Extracts the new kernel boot entry ID from `grub.cfg` (supports `sub_id > m_id` nested format).
   - Writes `GRUB_DEFAULT=saved` and `GRUB_SAVEDEFAULT=false`.
   - Runs `grub-set-default` and validates `saved_entry` via `grub-editenv`.
8. **System reboot**: prompts the user to reboot immediately to load the new kernel.


### Usage Example

```bash
# Download and run
curl -sSL -o /tmp/xanmod-install.sh https://raw.githubusercontent.com/88860/XanMod-ARM64-AutoBuild/main/xanmod-main-install.sh
bash /tmp/xanmod-install.sh
rm -f /tmp/xanmod-install.sh
```

> A system reboot is required after installation for the new kernel to take effect.


---


## Architecture Support Matrix


| Architecture | Install Source | Support Status | Notes |
| :--- | :--- | :--- | :--- |
| **ARM64 (aarch64)** | This repo GitHub Release `.deb` | ✅ Native support | Built by GitHub Actions natively |
| **amd64 (x64v2 / x64v3)** | Official Debian repo (`deb.xanmod.org`) | ✅ Script-compatible | Script includes x86-64-v2/v3 detection logic |
| Other architectures | — | ❌ Not supported | — |


---


## Security & Integrity

* **Upstream commit pinning**: Before building, the XanMod upstream commit ID is verified via `git rev-parse HEAD^{commit}` to ensure the exact expected commit is compiled.
* **Kernel configuration comparison**: After build, `/boot/config-<version>` is extracted from the `linux-image` deb and byte-compared (`cmp`) against `.config.final` produced during compilation. Any mismatch fails the publish.
* **deb structure validation**: `dpkg-deb --contents` verifies the image package contains the boot image and module directory, and the headers package contains kernel header paths. Missing any critical path aborts the release.
* **Debug symbol stripping**: `skipdbg=true` and `INSTALL_MOD_STRIP=1` are enabled during compilation to reduce package size and minimize kernel symbol exposure.
* **Asset integrity**: All release `.deb` files are accompanied by `SHA256SUMS` for manual download verification if needed.


---


## Notes

1. **Build hardware limitation**: CI runs on GitHub Actions `ubuntu-24.04-arm` native ARM64 runners; cross-compiling ARM64 kernels on x86 hosts is not supported.
2. **GRUB modification risk**: The install script modifies `/etc/default/grub` and `/boot/grub/grub.cfg`, and switches the default boot entry via `grub-set-default`. A reboot is required after installation for the new kernel to take effect.
3. **Network dependency**: The ARM64 install script requires access to `github.com` and `api.github.com` to fetch release metadata and download `.deb` packages.
4. **Old release cleanup**: CI automatically deletes previous releases and tags for the same channel, keeping only the latest. Back up older versions manually before they are purged if needed.
5. **No kernel configuration service**: This project provides standard-configuration automated builds only; it does not offer kernel `.config` customization. To change kernel options, adjust the `xanmod.arm64.fragment` generation logic or the Kconfig merge step in the workflow.


---


## License

This project is open-sourced under the MIT License.
