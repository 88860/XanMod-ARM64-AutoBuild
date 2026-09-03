#!/bin/bash

set -u

REPO="88860/XanMod-ARM64-AutoBuild"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_DEFAULT_FILE="/etc/default/grub"

die() {
    echo
    echo "错误: $1"
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行"
fi

for cmd in curl wget dpkg apt-get update-grub find grep sed sort head gpg; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
done

. /etc/os-release

ARCH="$(dpkg --print-architecture)"
CURRENT_KERNEL="$(uname -r)"

echo "========================================"
echo "XanMod MAIN 安装和升级"
echo "========================================"
echo
echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo

get_xanmod_kernel() {
    find /lib/modules \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
        grep -i 'xanmod' |
        sort -V |
        tail -n1
}

INSTALLED_XANMOD="$(get_xanmod_kernel)"

if [ -n "$INSTALLED_XANMOD" ]; then
    echo "已安装 XanMod: ${INSTALLED_XANMOD}"
else
    echo "XanMod: 未安装"
fi

echo

ONLINE_VERSION=""
NEED_INSTALL=1

if [ "$ARCH" = "arm64" ]; then

    echo "架构类型: ARM64"

    if ! command -v jq >/dev/null 2>&1; then
        echo "正在安装 jq"
        apt-get update || die "apt-get update 失败"
        apt-get install -y jq || die "jq 安装失败"
    fi

    RELEASES="$(
        curl -fsSL \
        "https://api.github.com/repos/${REPO}/releases"
    )" || die "无法获取 GitHub Release"

    ONLINE_VERSION="$(
        echo "$RELEASES" |
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
    )"

    [ -n "$ONLINE_VERSION" ] ||
        die "无法找到 ARM64 XanMod MAIN 版本"

    echo "在线版本: ${ONLINE_VERSION}"

    INSTALLED_VERSION="${INSTALLED_XANMOD%-arm64-main}"

    if [ -n "$INSTALLED_XANMOD" ] &&
       [ "$INSTALLED_VERSION" = "$ONLINE_VERSION" ]; then

        echo "XanMod 已是最新版本"
        NEED_INSTALL=0

    else

        NEED_INSTALL=1

    fi

elif [ "$ARCH" = "amd64" ]; then

    echo "架构类型: x86-64"

    if /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
        grep -q 'x86-64-v3 (supported, searched)'; then

        XANMOD_VER="x86-64-v3"
        XANMOD_PKG="linux-xanmod-x64v3"

    elif /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
        grep -q 'x86-64-v2 (supported, searched)'; then

        XANMOD_VER="x86-64-v2"
        XANMOD_PKG="linux-xanmod-x64v2"

    else

        XANMOD_VER="x86-64-v1"
        XANMOD_PKG=""

    fi

    echo "CPU 兼容级别: ${XANMOD_VER}"

    [ -n "$XANMOD_PKG" ] ||
        die "当前 CPU 不支持 XanMod x86-64-v2/v3"

    echo "XanMod 软件包: ${XANMOD_PKG}"

    if dpkg-query -W -f='${Status}' "$XANMOD_PKG" 2>/dev/null |
        grep -q "install ok installed"; then

        INSTALLED_PKG_VERSION="$(
            dpkg-query -W -f='${Version}' \
            "$XANMOD_PKG" 2>/dev/null
        )"

        echo "当前软件包版本: ${INSTALLED_PKG_VERSION}"

    else

        INSTALLED_PKG_VERSION=""

    fi

    XANMOD_REPO_URL="http://deb.xanmod.org/dists/${VERSION_CODENAME}/main/binary-amd64/Packages.gz"

    ONLINE_VERSION="$(
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
    )"

    [ -n "$ONLINE_VERSION" ] ||
        die "无法获取 XanMod 在线版本"

    echo "在线软件包版本: ${ONLINE_VERSION}"

    if [ -n "$INSTALLED_PKG_VERSION" ] &&
       [ "$INSTALLED_PKG_VERSION" = "$ONLINE_VERSION" ]; then

        echo "XanMod 已是最新版本"
        NEED_INSTALL=0

    else

        NEED_INSTALL=1

    fi

else

    die "不支持的架构: ${ARCH}"

fi

echo

if [ "$NEED_INSTALL" -eq 1 ]; then

    echo "检测到需要安装/升级 XanMod"

    read -r -p "是否继续？[y/N]: " CONFIRM

    case "$CONFIRM" in
        y|Y)
            ;;
        *)
            echo "已取消"
            exit 0
            ;;
    esac

    echo
    echo "开始安装/升级 XanMod"
    echo

    if [ "$ARCH" = "arm64" ]; then

        RELEASE_JSON="$(
            curl -fsSL \
            "https://api.github.com/repos/${REPO}/releases/tags/${ONLINE_VERSION}"
        )" || die "无法获取 Release 信息"

        TMP_DIR="$(mktemp -d)"

        trap 'rm -rf "$TMP_DIR"' EXIT

        IMAGE_URL="$(
            echo "$RELEASE_JSON" |
            jq -r '
                .assets[]
                | select(.name | test("^linux-image-.*arm64\\.deb$"))
                | .browser_download_url
            ' |
            head -n1
        )"

        HEADERS_URL="$(
            echo "$RELEASE_JSON" |
            jq -r '
                .assets[]
                | select(.name | test("^linux-headers-.*arm64\\.deb$"))
                | .browser_download_url
            ' |
            head -n1
        )"

        [ -n "$IMAGE_URL" ] ||
            die "找不到 ARM64 XanMod image 安装包"

        echo "下载: $(basename "$IMAGE_URL")"

        curl -fL \
            "$IMAGE_URL" \
            -o "$TMP_DIR/linux-image.deb" ||
            die "linux-image 下载失败"

        if [ -n "$HEADERS_URL" ] &&
           [ "$HEADERS_URL" != "null" ]; then

            echo "下载: $(basename "$HEADERS_URL")"

            curl -fL \
                "$HEADERS_URL" \
                -o "$TMP_DIR/linux-headers.deb" ||
                die "linux-headers 下载失败"
        fi

        echo
        echo "安装 ARM64 XanMod"

        if ! dpkg -i "$TMP_DIR"/*.deb; then
            echo
            echo "修复依赖"
            apt-get -f install -y ||
                die "ARM64 XanMod 安装失败"
        fi

    elif [ "$ARCH" = "amd64" ]; then

        mkdir -p /etc/apt/keyrings

        curl -fsSL \
            https://dl.xanmod.org/archive.key |
            gpg --dearmor \
            -o /etc/apt/keyrings/xanmod-archive-keyring.gpg ||
            die "XanMod 密钥安装失败"

        chmod 644 \
            /etc/apt/keyrings/xanmod-archive-keyring.gpg

        cat > /etc/apt/sources.list.d/xanmod.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main
EOF

        apt-get update ||
            die "apt-get update 失败"

        apt-get install -y "$XANMOD_PKG" ||
            die "XanMod 安装/升级失败"

    fi

    echo
    echo "安装/升级完成"
    echo

else

    echo "无需安装或升级"
    echo "直接进入 GRUB 配置"
    echo

fi

XANMOD_KERNEL="$(get_xanmod_kernel)"

[ -n "$XANMOD_KERNEL" ] ||
    die "没有找到 XanMod 内核"

echo "XanMod 内核: ${XANMOD_KERNEL}"
echo

echo "更新 GRUB"

update-grub ||
    die "update-grub 失败"

[ -f "$GRUB_CFG" ] ||
    die "找不到 ${GRUB_CFG}"

echo
echo "定位 XanMod GRUB 启动项"

XANMOD_GRUB_ID="$(
    grep "menuentry " "$GRUB_CFG" |
    grep "Linux ${XANMOD_KERNEL}" |
    grep -v "recovery mode" |
    sed -n "s/.*--id[[:space:]]*'\([^']*\)'.*/\1/p" |
    head -n1
)"

if [ -z "$XANMOD_GRUB_ID" ]; then

    XANMOD_GRUB_ID="$(
        grep "menuentry " "$GRUB_CFG" |
        grep "$XANMOD_KERNEL" |
        grep -vi "recovery" |
        sed -n "s/.*--id[[:space:]]*'\([^']*\)'.*/\1/p" |
        head -n1
    )"

fi

[ -n "$XANMOD_GRUB_ID" ] ||
    die "无法找到 XanMod GRUB 启动项"

echo "XanMod GRUB ID:"
echo "$XANMOD_GRUB_ID"

echo

if grep -q '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; then

    sed -i \
        's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
        "$GRUB_DEFAULT_FILE"

else

    echo 'GRUB_DEFAULT=saved' >> "$GRUB_DEFAULT_FILE"

fi

if grep -q '^GRUB_SAVEDEFAULT=' "$GRUB_DEFAULT_FILE"; then

    sed -i \
        's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=false/' \
        "$GRUB_DEFAULT_FILE"

else

    echo 'GRUB_SAVEDEFAULT=false' >> "$GRUB_DEFAULT_FILE"

fi

command -v grub-set-default >/dev/null 2>&1 ||
    die "找不到 grub-set-default"

command -v grub-editenv >/dev/null 2>&1 ||
    die "找不到 grub-editenv"

grub-set-default "$XANMOD_GRUB_ID" ||
    die "设置 GRUB 默认启动项失败"

SAVED_ENTRY="$(
    grub-editenv /boot/grub/grubenv list 2>/dev/null |
    sed -n 's/^saved_entry=//p'
)"

echo
echo "GRUB 默认项:"
echo "${SAVED_ENTRY:-未设置}"

if [ "$SAVED_ENTRY" != "$XANMOD_GRUB_ID" ]; then

    echo
    echo "GRUB 默认项验证失败"
    echo "目标: $XANMOD_GRUB_ID"
    echo "实际: ${SAVED_ENTRY:-未设置}"
    exit 1

fi

update-grub ||
    die "最终 update-grub 失败"

echo
echo "========================================"
echo "XanMod 配置完成"
echo "========================================"
echo
echo "XanMod: ${XANMOD_KERNEL}"
echo "GRUB 默认: ${XANMOD_GRUB_ID}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo
echo "下次启动将默认进入 XanMod"
echo

read -r -p "是否现在重启？[y/N]: " REBOOT_CONFIRM

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "正在重启"
        reboot
        ;;
    *)
        echo
        echo "未重启系统"
        ;;
esac
