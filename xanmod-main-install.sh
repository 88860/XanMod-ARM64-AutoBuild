#!/bin/bash

set -u

SCRIPT_NAME="XanMod MAIN 安装和升级"

die() {
    echo
    echo "错误: $1"
    echo "操作已停止，不会重启系统。"
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"
}

require_root

for cmd in awk sed grep curl gzip; do
    command -v "$cmd" >/dev/null 2>&1 || die "未找到 $cmd"
done

echo "========================================"
echo "      ${SCRIPT_NAME}"
echo "========================================"
echo

echo "[1/5] 检测系统信息"
echo

[ -f /etc/os-release ] || die "无法读取 /etc/os-release"
. /etc/os-release

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
CURRENT_KERNEL=$(uname -r)

echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo

if [ "$ARCH" = "amd64" ]; then

    echo "架构类型: x86-64"
    echo

    # 保留原有 v2/v3 检测逻辑
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

    [ -n "$XANMOD_PKG" ] || die "当前 CPU 不支持 XanMod x86-64-v2/v3"

    echo "XanMod 适配版本: ${XANMOD_PKG}"

elif [ "$ARCH" = "arm64" ]; then

    echo "架构类型: ARM64"

    XANMOD_VER="ARM64"
    XANMOD_PKG=""

else

    die "不支持的架构: ${ARCH}"
fi

echo

INSTALLED_XANMOD=""

for kernel_dir in /lib/modules/*; do
    [ -d "$kernel_dir" ] || continue

    kernel_name=$(basename "$kernel_dir")

    if [[ "$kernel_name" == *xanmod* ]]; then
        INSTALLED_XANMOD="$kernel_name"
    fi
done

if [ -n "$INSTALLED_XANMOD" ]; then
    echo "当前已安装 XanMod 内核: ${INSTALLED_XANMOD}"
else
    echo "当前 XanMod 状态: 未安装"
fi

echo
echo "[2/5] 检测在线 XanMod MAIN 版本"
echo

ONLINE_VERSION=""

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

    [ -n "$ONLINE_VERSION" ] || die "无法获取 XanMod MAIN 在线版本"

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
        die "ARM64 检测需要 jq，请先安装 jq"
    fi

    [ -n "$RELEASE_TAG" ] || die "无法找到 XanMod ARM64 MAIN 版本"

    ONLINE_VERSION="$RELEASE_TAG"

    echo "在线版本: ${ONLINE_VERSION}"
fi

echo

ACTION="安装"

if [ -n "$INSTALLED_XANMOD" ]; then
    ACTION="升级"
fi

if [ "$ARCH" = "amd64" ] && [ -n "$INSTALLED_XANMOD" ]; then

    INSTALLED_PKG_VERSION=$(
        dpkg-query -W -f='${Version}' "$XANMOD_PKG" 2>/dev/null || true
    )

    if [ -n "$INSTALLED_PKG_VERSION" ]; then

        echo "当前软件包版本: ${INSTALLED_PKG_VERSION}"
        echo "在线软件包版本: ${ONLINE_VERSION}"
        echo

        if [ "$INSTALLED_PKG_VERSION" = "$ONLINE_VERSION" ]; then
            echo "XanMod MAIN 已经是最新版本。"
            echo

            read -r -p "是否重新安装当前版本？[y/N]: " REINSTALL

            case "$REINSTALL" in
                y|Y) ACTION="重新安装" ;;
                *) echo "无需操作。"; exit 0 ;;
            esac
        fi
    fi

elif [ "$ARCH" = "arm64" ] && [ -n "$INSTALLED_XANMOD" ]; then

    CURRENT_XANMOD_VERSION="${INSTALLED_XANMOD%%-xanmod*}"

    echo "当前 XanMod 内核: ${INSTALLED_XANMOD}"
    echo "在线 XanMod 版本: ${ONLINE_VERSION}"
    echo

    if [[ "$INSTALLED_XANMOD" == *"$ONLINE_VERSION"* ]]; then
        echo "当前 XanMod 已经是在线版本。"
        echo

        read -r -p "是否重新安装当前版本？[y/N]: " REINSTALL

        case "$REINSTALL" in
            y|Y) ACTION="重新安装" ;;
            *) echo "无需操作。"; exit 0 ;;
        esac
    fi
fi

echo "操作类型: ${ACTION}"
echo

read -r -p "是否${ACTION} XanMod MAIN 内核？[y/N]: " CONFIRM

case "$CONFIRM" in
    y|Y) ;;
    *) echo "已取消。"; exit 0 ;;
esac

echo
echo "[3/5] 开始${ACTION} XanMod MAIN"
echo

if [ "$ARCH" = "amd64" ]; then

    mkdir -p /etc/apt/keyrings

    curl -fsSL https://dl.xanmod.org/archive.key |
        gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg ||
        die "XanMod 密钥安装失败"

    chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/xanmod.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main
EOF

    echo "更新软件包索引..."

    apt-get update ||
        die "apt-get update 失败"

    echo
    echo "安装 / 升级 ${XANMOD_PKG}..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$XANMOD_PKG" ||
        die "XanMod 安装 / 升级失败"

elif [ "$ARCH" = "arm64" ]; then

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    echo "获取 XanMod ARM64 MAIN 安装包..."

    RELEASE_JSON=$(curl -fsSL \
        "https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases") ||
        die "无法获取 GitHub Release"

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

    [ -n "$ASSETS" ] || die "没有找到 ARM64 XanMod MAIN 安装包"

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
        echo "尝试修复依赖..."

        apt-get -f install -y ||
            die "ARM64 XanMod 安装失败"
    fi

fi

echo
echo "========================================"
echo "XanMod ${ACTION}成功"
echo "========================================"
echo

XANMOD_KERNEL=""

for kernel_dir in /lib/modules/*; do

    [ -d "$kernel_dir" ] || continue

    kernel_name=$(basename "$kernel_dir")

    if [[ "$kernel_name" == *xanmod* ]]; then
        XANMOD_KERNEL="$kernel_name"
    fi

done

[ -n "$XANMOD_KERNEL" ] ||
    die "安装成功，但无法找到实际 XanMod 内核"

echo "检测到 XanMod 内核:"
echo "${XANMOD_KERNEL}"
echo

echo "[4/5] 设置 XanMod 为默认启动内核"
echo

command -v update-grub >/dev/null 2>&1 ||
    die "未找到 update-grub"

command -v grub-set-default >/dev/null 2>&1 ||
    die "未找到 grub-set-default"

command -v grub-editenv >/dev/null 2>&1 ||
    die "未找到 grub-editenv"

if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
else
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

update-grub ||
    die "update-grub 执行失败"

echo
echo "正在搜索 XanMod GRUB 启动项..."
echo

# 按 XanMod 名称寻找正式 menuentry，并处理 submenu 层级
GRUB_TARGET=$(
    awk '
        function extract_id(line, x) {

            if (match(line, /\$menuentry_id_option '\''[^'\'']+'\''/)) {
                x=substr(line, RSTART, RLENGTH)
                sub(/^\$menuentry_id_option[[:space:]]+'\''/, "", x)
                sub(/'\''$/, "", x)
                return x
            }

            if (match(line, /--id[[:space:]]+'\''[^'\'']+'\''/)) {
                x=substr(line, RSTART, RLENGTH)
                sub(/^--id[[:space:]]+'\''/, "", x)
                sub(/'\''$/, "", x)
                return x
            }

            return ""
        }

        {
            line=$0

            if (match(line, /^submenu /)) {
                submenu_id=extract_id(line)
                submenu_depth=1
                next
            }

            if (match(line, /^menuentry /)) {

                entry_id=extract_id(line)
                lower=tolower(line)

                if (
                    index(lower, "xanmod") > 0 &&
                    index(lower, "recovery") == 0 &&
                    entry_id != ""
                ) {

                    if (submenu_id != "") {
                        print submenu_id ">" entry_id
                    } else {
                        print entry_id
                    }

                    exit
                }
            }

            if (submenu_id != "" && line ~ /^}/) {
                submenu_id=""
            }
        }
    ' /boot/grub/grub.cfg
)

[ -n "$GRUB_TARGET" ] ||
    die "无法找到名称包含 XanMod 的 GRUB 正式启动项"

echo "找到 XanMod GRUB 启动项:"
echo "${GRUB_TARGET}"
echo

grub-set-default "$GRUB_TARGET" ||
    die "设置 GRUB 默认启动失败"

SAVED_ENTRY=$(
    grub-editenv list 2>/dev/null |
    sed -n 's/^saved_entry=//p'
)

if [ "$SAVED_ENTRY" != "$GRUB_TARGET" ]; then

    echo "GRUB 默认启动验证失败。"
    echo
    echo "期望:"
    echo "$GRUB_TARGET"
    echo
    echo "实际:"
    echo "${SAVED_ENTRY:-未设置}"

    die "GRUB 默认启动验证失败"
fi

echo "GRUB 默认启动项设置成功。"
echo
echo "目标启动项: XanMod"
echo "目标内核: ${XANMOD_KERNEL}"
echo
echo "注意：这里只验证 GRUB 默认项。"
echo "重启后的实际运行内核请使用 uname -r 确认。"

echo
echo "========================================"
echo "[5/5] 操作完成"
echo "========================================"
echo

echo "XanMod MAIN 已成功${ACTION}。"
echo
echo "当前运行内核: ${CURRENT_KERNEL}"
echo "GRUB 默认启动: XanMod"
echo "目标内核: ${XANMOD_KERNEL}"
echo

read -r -p "是否现在重启系统？[y/N]: " REBOOT_CONFIRM

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "正在重启系统
