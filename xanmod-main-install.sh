#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

clear

echo "========================================"
echo "        XanMod MAIN 安装"
echo "========================================"
echo

echo "[1/5] 检测系统信息"
echo

if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "ERROR: 无法检测系统信息"
    exit 1
fi

ARCH=$(dpkg --print-architecture)

echo "系统: ${PRETTY_NAME:-$NAME}"
echo "架构: $ARCH"
echo "当前运行内核: $(uname -r)"
echo

case "$ARCH" in

    amd64)

        echo "架构类型: x86-64"
        echo

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

        echo "CPU 兼容级别: $XANMOD_VER"

        if [ -z "$XANMOD_PKG" ]; then
            echo
            echo "ERROR: CPU 不支持 x86-64-v2，无法安装 XanMod MAIN"
            exit 1
        fi

        echo "XanMod 适配版本: $XANMOD_PKG"
        echo

        echo "[2/5] 检测在线 XanMod MAIN 版本"
        echo

        if ! command -v curl >/dev/null 2>&1; then
            echo "检测依赖 curl 未安装"
            echo "请先执行: apt-get update && apt-get install -y curl"
            exit 1
        fi

        XANMOD_REPO_URL="http://deb.xanmod.org/dists/${VERSION_CODENAME}/main/binary-amd64/Packages.gz"

        ONLINE_VERSION=$(curl -fsSL "$XANMOD_REPO_URL" |
            gzip -dc |
            awk -v pkg="$XANMOD_PKG" '
                $1 == "Package:" && $2 == pkg {found=1}
                found && $1 == "Version:" {print $2; exit}
                found && $1 == "Package:" && $2 != pkg {exit}
            ')

        if [ -z "$ONLINE_VERSION" ]; then
            echo "ERROR: 无法获取 XanMod 在线版本"
            exit 1
        fi

        echo "在线版本: $ONLINE_VERSION"
        echo "安装包: $XANMOD_PKG"

        ;;

    arm64)

        echo "架构类型: ARM64"
        echo

        echo "[2/5] 检测在线 XanMod MAIN 版本"
        echo

        if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
            echo "检测依赖 curl 或 jq 未安装"
            echo "请先安装 curl 和 jq"
            exit 1
        fi

        RELEASE=$(curl -fsSL \
            'https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases?per_page=100' |
            jq -r '
                .[] |
                select(.draft == false and .prerelease == false) |
                select(
                    ((.tag_name | ascii_downcase) | contains("main")) or
                    ((.name | ascii_downcase) | contains("main")) or
                    ((.body | ascii_downcase) | contains("main"))
                ) |
                .tag_name
            ' |
            head -n1)

        if [ -z "$RELEASE" ]; then
            echo "ERROR: 未找到 ARM64 XanMod MAIN 在线版本"
            exit 1
        fi

        ONLINE_VERSION="$RELEASE"

        echo "在线版本: $ONLINE_VERSION"

        ;;

    *)

        echo
        echo "ERROR: 不支持的架构: $ARCH"
        exit 1
        ;;

esac

echo
echo "========================================"
echo "检测完成"
echo "========================================"
echo
echo "系统: ${PRETTY_NAME:-$NAME}"
echo "架构: $ARCH"
echo "当前运行内核: $(uname -r)"
echo "XanMod 类型: MAIN"
echo "在线版本: $ONLINE_VERSION"

if [ "$ARCH" = "amd64" ]; then
    echo "CPU 适配: $XANMOD_VER"
    echo "安装包: $XANMOD_PKG"
fi

echo
read -r -p "是否安装 XanMod MAIN 内核？[y/N]: " CONFIRM

case "$CONFIRM" in
    y|Y)
        ;;
    *)
        echo
        echo "已取消安装。"
        exit 0
        ;;
esac

echo
echo "[3/5] 开始安装 XanMod MAIN"
echo

apt-get update

apt-get install -y wget curl gpg ca-certificates jq grub-common grub2-common

case "$ARCH" in

    amd64)

        install -d -m 0755 /etc/apt/keyrings

        wget -qO - https://dl.xanmod.org/archive.key |
            gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg

        chmod 0644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

        printf '%s\n' \
            "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main" \
            > /etc/apt/sources.list.d/xanmod-release.list

        apt-get update

        echo
        echo "正在安装: $XANMOD_PKG"
        echo "目标版本: $ONLINE_VERSION"
        echo

        apt-get install -y "$XANMOD_PKG"

        ;;

    arm64)

        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT

        echo "正在下载 ARM64 MAIN 内核..."
        echo

        curl -fsSL \
            "https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases/tags/$RELEASE" |
            jq -r '
                .assets[] |
                select(.name | test("linux-(image|headers)-.*arm64\\.deb$")) |
                .browser_download_url
            ' |
            wget -q -i- -P "$TMPDIR"

        if ! ls "$TMPDIR"/linux-image-*_arm64.deb >/dev/null 2>&1; then
            echo "ERROR: ARM64 内核镜像下载失败"
            exit 1
        fi

        if ! ls "$TMPDIR"/linux-headers-*_arm64.deb >/dev/null 2>&1; then
            echo "ERROR: ARM64 headers 下载失败"
            exit 1
        fi

        apt-get install -y "$TMPDIR"/*.deb

        ;;

esac

echo
echo "========================================"
echo "XanMod 内核安装成功"
echo "========================================"
echo

XANMOD_KERNEL=$(find /boot \
    -maxdepth 1 \
    -type f \
    -name 'vmlinuz-*xanmod*' \
    -printf '%f\n' |
    sed 's/^vmlinuz-//' |
    sort -V |
    tail -n1)

if [ -z "$XANMOD_KERNEL" ]; then
    echo "ERROR: 安装完成后未在 /boot 找到 XanMod 内核"
    exit 1
fi

echo "检测到 XanMod 内核:"
echo "$XANMOD_KERNEL"

echo
echo "[4/5] 设置 XanMod 为默认启动内核"
echo

update-grub

GRUB_ID=$(awk -v kernel="$XANMOD_KERNEL" '
    /menuentry / && index($0, "vmlinuz-" kernel) {
        if (match($0, /--id '\''[^'\'']+'\''/)) {
            id=substr($0, RSTART+6, RLENGTH-7)
            print id
            exit
        }
    }
' /boot/grub/grub.cfg)

if [ -z "$GRUB_ID" ]; then
    GRUB_ID=$(grep -B20 -A5 "vmlinuz-$XANMOD_KERNEL" /boot/grub/grub.cfg |
        grep -oP -- "--id '\''\K[^'\'']+" |
        tail -n1)
fi

if [ -z "$GRUB_ID" ]; then
    echo "ERROR: 无法找到 XanMod 对应的 GRUB ID"
    exit 1
fi

echo "GRUB ID: $GRUB_ID"

sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
sed -i '/^GRUB_SAVEDEFAULT=/d' /etc/default/grub

printf '%s\n' \
    'GRUB_DEFAULT=saved' \
    'GRUB_SAVEDEFAULT=false' \
    >> /etc/default/grub

update-grub

grub-set-default "$GRUB_ID"

SAVED_ENTRY=$(grub-editenv /boot/grub/grubenv list 2>/dev/null |
    sed -n 's/^saved_entry=//p')

if [ "$SAVED_ENTRY" != "$GRUB_ID" ]; then
    echo
    echo "ERROR: GRUB 默认内核设置失败"
    echo "期望: $GRUB_ID"
    echo "实际: $SAVED_ENTRY"
    exit 1
fi

echo
echo "========================================"
echo "默认启动内核设置成功"
echo "========================================"
echo
echo "默认内核: $XANMOD_KERNEL"
echo "GRUB ID: $GRUB_ID"
echo

echo "[5/5] 重启确认"
echo

read -r -p "是否立即重启并进入 XanMod 内核？[y/N]: " REBOOT_CONFIRM

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "系统将在 3 秒后重启..."
        sleep 3
        reboot
        ;;
    *)
        echo
        echo "已取消重启。"
        echo
        echo "当前内核: $(uname -r)"
        echo "下次启动默认内核: $XANMOD_KERNEL"
        echo
        echo "执行 reboot 后将进入 XanMod。"
        ;;
esac
