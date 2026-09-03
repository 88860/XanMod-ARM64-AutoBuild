#!/bin/bash

set -u

SCRIPT_NAME="XanMod MAIN 安装和升级"

# ============================================================
# 基础函数
# ============================================================

die() {
    echo
    echo "错误: $1"
    echo "操作已停止，不会重启系统。"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 运行此脚本"
    fi
}

command -v curl >/dev/null 2>&1 || die "未找到 curl，请先安装 curl"
command -v awk >/dev/null 2>&1 || die "未找到 awk"
command -v gzip >/dev/null 2>&1 || die "未找到 gzip"

require_root

# ============================================================
# 系统检测
# ============================================================

echo "========================================"
echo "      ${SCRIPT_NAME}"
echo "========================================"
echo

echo "[1/5] 检测系统信息"
echo

if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    die "无法读取 /etc/os-release"
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
CURRENT_KERNEL=$(uname -r)

echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo

# ============================================================
# XanMod 架构判断
# ============================================================

if [ "$ARCH" = "amd64" ]; then

    echo "架构类型: x86-64"
    echo

    # 注意：
    # 这里严格保留原来的 v2/v3 检测逻辑
    if /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3 (supported, searched)'; then
        XANMOD_VER="x86-64-v3"
        XANMOD_PKG="linux-xanmod-x64v3"
    elif /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v2 (supported, searched)'; then
        XANMOD_VER="x86-64-v2"
        XANMOD_PKG="linux-xanmod-x64v2"
    else
        XANMOD_VER="x86-64-v1"
        XANMOD_PKG=""
    fi

    echo "CPU 兼容级别: ${XANMOD_VER}"

    if [ -z "$XANMOD_PKG" ]; then
        die "当前 CPU 不支持 XanMod x86-64-v2/v3"
    fi

    echo "XanMod 适配版本: ${XANMOD_PKG}"

elif [ "$ARCH" = "arm64" ]; then

    echo "架构类型: ARM64"
    XANMOD_VER="ARM64"
    XANMOD_PKG=""

else

    die "不支持的架构: ${ARCH}"
fi

echo

# ============================================================
# 检测当前已安装 XanMod 内核
# ============================================================

INSTALLED_XANMOD=""

for kernel in /lib/modules/*; do
    [ -d "$kernel" ] || continue

    k=$(basename "$kernel")

    case "$k" in
        *xanmod*)
            INSTALLED_XANMOD="$k"
            ;;
    esac
done

if [ -n "$INSTALLED_XANMOD" ]; then
    echo "当前已安装 XanMod 内核: ${INSTALLED_XANMOD}"
else
    echo "当前 XanMod 状态: 未安装"
fi

echo

# ============================================================
# 检测在线版本
# ============================================================

echo "[2/5] 检测在线 XanMod MAIN 版本"
echo

ONLINE_VERSION=""
ONLINE_KERNEL=""

if [ "$ARCH" = "amd64" ]; then

    XANMOD_REPO_URL="http://deb.xanmod.org/dists/${VERSION_CODENAME}/main/binary-amd64/Packages.gz"

    ONLINE_VERSION=$(
        curl -fsSL "$XANMOD_REPO_URL" 2>/dev/null |
        gzip -dc 2>/dev/null |
        awk -v pkg="$XANMOD_PKG" '
            $1 == "Package:" && $2 == pkg {
                found=1
            }
            found && $1 == "Version:" {
                print $2
                exit
            }
        '
    )

    if [ -z "$ONLINE_VERSION" ]; then
        die "无法获取 XanMod MAIN 在线版本"
    fi

    echo "在线软件包版本: ${ONLINE_VERSION}"
    echo "软件包: ${XANMOD_PKG}"

elif [ "$ARCH" = "arm64" ]; then

    API_URL="https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases"

    RELEASE_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) ||
        die "无法获取 XanMod ARM64 在线版本"

    if command -v jq >/dev/null 2>&1; then

        RELEASE_TAG=$(
            echo "$RELEASE_JSON" |
            jq -r '
                .[]
                | select(.draft == false)
                | select(.prerelease == false)
                | select(
                    ((.tag_name // "") | ascii_downcase | contains("main"))
                    or
                    ((.name // "") | ascii_downcase | contains("main"))
                    or
                    ((.body // "") | ascii_downcase | contains("main"))
                )
                | .tag_name
            ' |
            head -n1
        )

    else

        RELEASE_TAG=$(echo "$RELEASE_JSON" |
            grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
            head -n1 |
            sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"$//')
    fi

    [ -n "$RELEASE_TAG" ] ||
        die "无法找到 XanMod ARM64 MAIN 版本"

    ONLINE_VERSION="$RELEASE_TAG"

    echo "在线版本: ${ONLINE_VERSION}"
fi

echo
echo "========================================"
echo "检测完成"
echo "========================================"
echo

# ============================================================
# 判断安装 / 升级 / 已是最新
# ============================================================

ACTION="安装"

if [ -n "$INSTALLED_XANMOD" ]; then
    ACTION="升级"
fi

if [ "$ARCH" = "amd64" ] && [ -n "$INSTALLED_XANMOD" ]; then

    # 查询当前软件包版本
    INSTALLED_PKG_VERSION=$(
        dpkg-query -W -f='${Version}' "$XANMOD_PKG" 2>/dev/null || true
    )

    if [ -n "$INSTALLED_PKG_VERSION" ]; then
        echo "当前软件包版本: ${INSTALLED_PKG_VERSION}"
        echo "在线软件包版本: ${ONLINE_VERSION}"

        if [ "$INSTALLED_PKG_VERSION" = "$ONLINE_VERSION" ]; then
            echo
            echo "XanMod MAIN 已经是最新版本。"
            echo

            read -r -p "仍然重新安装当前版本吗？[y/N]: " REINSTALL

            case "$REINSTALL" in
                y|Y)
                    ACTION="重新安装"
                    ;;
                *)
                    echo
                    echo "无需操作。"
                    exit 0
                    ;;
            esac
        else
            ACTION="升级"
        fi
    fi
fi

echo "操作类型: ${ACTION}"
echo

read -r -p "是否${ACTION} XanMod MAIN 内核？[y/N]: " CONFIRM

case "$CONFIRM" in
    y|Y)
        ;;
    *)
        echo
        echo "已取消。"
        exit 0
        ;;
esac

# ============================================================
# 安装 / 升级
# ============================================================

echo
echo "[3/5] 开始${ACTION} XanMod MAIN"
echo

if [ "$ARCH" = "amd64" ]; then

    echo "配置 XanMod 软件源..."

    mkdir -p /etc/apt/keyrings

    curl -fsSL \
        https://dl.xanmod.org/archive.key |
        gpg --dearmor \
        -o /etc/apt/keyrings/xanmod-archive-keyring.gpg

    chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/xanmod.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main
EOF

    echo "更新软件包索引..."

    apt-get update

    echo
    echo "安装 / 升级 ${XANMOD_PKG}..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$XANMOD_PKG"

    if [ $? -ne 0 ]; then
        die "XanMod 安装 / 升级失败"
    fi

elif [ "$ARCH" = "arm64" ]; then

    echo "获取 XanMod ARM64 MAIN 安装包..."

    TMP_DIR=$(mktemp -d)

    cleanup() {
        rm -rf "$TMP_DIR"
    }

    trap cleanup EXIT

    RELEASE_JSON=$(curl -fsSL \
        "https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases") ||
        die "无法获取 GitHub Release"

    if command -v jq >/dev/null 2>&1; then

        ASSETS=$(
            echo "$RELEASE_JSON" |
            jq -r '
                .[]
                | select(.draft == false)
                | select(.prerelease == false)
                | select(
                    ((.tag_name // "") | ascii_downcase | contains("main"))
                    or
                    ((.name // "") | ascii_downcase | contains("main"))
                    or
                    ((.body // "") | ascii_downcase | contains("main"))
                )
                | .assets[]
                | select(
                    (.name | test("^linux-(image|headers)-.*arm64\\.deb$"))
                )
                | .browser_download_url
            ' |
            head -n2
        )

    else
        ASSETS=$(
            echo "$RELEASE_JSON" |
            grep -o 'https[^"]*linux-[^"]*arm64\.deb' |
            head -n2
        )
    fi

    [ -n "$ASSETS" ] ||
        die "没有找到 ARM64 XanMod MAIN 安装包"

    echo "$ASSETS" |
    while read -r URL; do
        [ -n "$URL" ] || continue

        FILE="$TMP_DIR/$(basename "$URL")"

        echo "下载: $(basename "$URL")"

        curl -fL "$URL" -o "$FILE" ||
            die "下载失败: $URL"
    done

    echo
    echo "安装 ARM64 XanMod..."

    dpkg -i "$TMP_DIR"/*.deb

    if [ $? -ne 0 ]; then
        echo
        echo "检测到依赖问题，尝试自动修复..."

        apt-get -f install -y

        if [ $? -ne 0 ]; then
            die "ARM64 XanMod 安装失败"
        fi
    fi

fi

echo
echo "========================================"
echo "XanMod ${ACTION}成功"
echo "========================================"
echo

# ============================================================
# 动态检测实际安装的 XanMod 内核
# ============================================================

XANMOD_KERNEL=""

for kernel_dir in /lib/modules/*; do
    [ -d "$kernel_dir" ] || continue

    k=$(basename "$kernel_dir")

    if [[ "$k" == *xanmod* ]]; then
        XANMOD_KERNEL="$k"
    fi
done

[ -n "$XANMOD_KERNEL" ] ||
    die "安装成功，但无法找到实际 XanMod 内核"

echo "检测到 XanMod 内核:"
echo "${XANMOD_KERNEL}"

echo

# ============================================================
# 设置 GRUB 默认启动
# ============================================================

echo "[4/5] 设置 XanMod 为默认启动内核"
echo

# 确保 grub 使用 saved 模式
if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
else
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

# 生成 grub.cfg
update-grub

if [ $? -ne 0 ]; then
    die "update-grub 执行失败"
fi

# ============================================================
# 从 grub.cfg 动态获取 XanMod menuentry ID
# 同时兼容：
#   $menuentry_id_option 'xxxx'
#   --id 'xxxx'
# ============================================================

GRUB_ID=$(
    awk -v kernel="$XANMOD_KERNEL" '
        /menuentry / {
            id=""
            active=1

            line=$0

            if (match(line, /\$menuentry_id_option '\''[^'\'']+'\''/)) {
                x=substr(line, RSTART, RLENGTH)
                sub(/^\$menuentry_id_option[[:space:]]+'\''/, "", x)
                sub(/'\''$/, "", x)
                id=x
            }
            else if (match(line, /--id[[:space:]]+'\''[^'\'']+'\''/)) {
                x=substr(line, RSTART, RLENGTH)
                sub(/^--id[[:space:]]+'\''/, "", x)
                sub(/'\''$/, "", x)
                id=x
            }
        }

        active && index($0, "vmlinuz-" kernel) {
            if (id != "") {
                print id
                exit
            }
        }
    ' /boot/grub/grub.cfg
)

if [ -z "$GRUB_ID" ]; then
    die "无法找到 XanMod 对应的 GRUB ID"
fi

echo "XanMod GRUB ID:"
echo "$GRUB_ID"
echo

# ============================================================
# 写入 saved_entry
# ============================================================

if ! command -v grub-set-default >/dev/null 2>&1; then
    die "未找到 grub-set-default"
fi

grub-set-default "$GRUB_ID"

if [ $? -ne 0 ]; then
    die "设置 GRUB 默认启动失败"
fi

# ============================================================
# 验证
# ============================================================

SAVED_ENTRY=$(grub-editenv list 2>/dev/null |
    sed -n 's/^saved_entry=//p')

if [ "$SAVED_ENTRY" != "$GRUB_ID" ]; then
    die "GRUB 默认启动验证失败"
fi

echo "GRUB 默认启动设置成功。"
echo
echo "默认启动内核:"
echo "${XANMOD_KERNEL}"

# ============================================================
# 重启确认
# ============================================================

echo
echo "========================================"
echo "[5/5] 操作完成"
echo "========================================"
echo

echo "XanMod MAIN 已成功${ACTION}。"
echo "下次启动将默认进入:"
echo "${XANMOD_KERNEL}"
echo

read -r -p "是否现在重启系统？[y/N]: " REBOOT_CONFIRM

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "系统正在重启..."
        reboot
        ;;
    *)
        echo
        echo "已取消重启。"
        echo "当前系统仍运行:"
        echo "${CURRENT_KERNEL}"
        echo
        echo "下次重启将默认进入:"
        echo "${XANMOD_KERNEL}"
        ;;
esac
