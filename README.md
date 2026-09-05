# XanMod ARM64 自动构建

基于 GitHub Actions 的原生 ARM64 (aarch64) XanMod 内核自动编译与发布平台。

## 特性

* 原生 ARM64 编译：使用纯原生环境，无交叉编译性能损耗。
* LLVM/Clang 22：采用最新 Clang 工具链编译，支持 LTO 与 CFI 等高级性能与安全特性。
* 三通道同步：全自动追踪并编译 XanMod 的 EDGE、MAIN、LTS 最新版本。
* 开箱即用：提供标准 Debian 打包（.deb），极致精简剥离无用调试符号。

## 下载与安装

1. 访问本仓库的 Releases 页面。
2. 选择你需要的版本（EDGE / MAIN / LTS），下载对应的 3 个 .deb 文件：
   * linux-image-*.deb
   * linux-headers-*.deb
   * linux-libc-dev-*.deb
3. 在终端中执行安装：
   ```bash
   sudo dpkg -i *.deb
