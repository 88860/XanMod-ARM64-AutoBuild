基于 GitHub Actions 的原生 ARM64 (aarch64) XanMod 内核自动编译与发布平台。

### 特性
* **原生 ARM64 编译**：使用纯原生环境，无交叉编译性能损耗。
* **LLVM/Clang 22**：采用最新 Clang 工具链编译，支持 LTO 与 CFI 等高级性能与安全特性。
* **三通道同步**：全自动追踪并编译 XanMod 的 EDGE、MAIN、LTS 最新版本。
* **开箱即用**：提供标准 Debian 打包（.deb），极致精简剥离无用调试符号。

### 下载与安装
```bash
curl -sSL https://raw.githubusercontent.com/88860/XanMod-ARM64-AutoBuild/main/xanmod-main-install.sh | bash
