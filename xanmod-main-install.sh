#!/bin/bash

set -u

die() {
    echo "错误: $1"
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"
}

require_root

for cmd in awk sed grep curl gzip dpkg dpkg-query; do
    command -v "$cmd" >/dev/null 2>&1 || die "未找到 $cmd"
done

echo "XanMod MAIN 安装和升级"
echo "============================================"
echo

[ -f /etc/os-release ] || die "无法读取 /etc/os-release"
. /etc/os-release

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
CURRENT_KERNEL=$(uname -r)

echo "[1/4] 系统检测"
echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前内核: ${CURRENT_KERNEL}"
echo

if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "amd64" ]; then
    die "不支持的架构: ${ARCH}"
fi

INSTALLED_XANMOD=""
for kernel_dir in /lib/modules/*; do
    [ -d "$kernel_dir" ] || continue
    kernel_name=$(basename "$kernel_dir")
    if [[ "$kernel_name" == *xanmod* ]]; then
        INSTALLED_XANMOD="$kernel_name"
        break
    fi
done

if [ -z "$INSTALLED_XANMOD" ]; then
    die "未找到已安装的 XanMod 内核"
fi

echo "XanMod 内核: ${INSTALLED_XANMOD}"
echo

echo "[2/4] 版本检测"
if [ "$ARCH" = "arm64" ]; then

    command -v jq >/dev/null 2>&1 || die "需要 jq"

    RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases" 2>/dev/null) ||
        die "无法获取在线版本"

    ONLINE_VERSION=$(
        echo "$RELEASE_JSON" |
        jq -r '.[]
            | select(.draft == false)
            | select(.prerelease == false)
            | select(
                ((.tag_name // "") | ascii_downcase | contains("main"))
                or ((.name // "") | ascii_downcase | contains("main"))
            )
            | .tag_name' |
        head -n1
    )

    [ -n "$ONLINE_VERSION" ] || die "无法找到在线版本"

    echo "在线版本: ${ONLINE_VERSION}"
    echo "已安装版本: ${INSTALLED_XANMOD}"
    echo

    if [ "$INSTALLED_XANMOD" != "${ONLINE_VERSION}-arm64-main" ] && 
       [ "$INSTALLED_XANMOD" != "${ONLINE_VERSION}" ]; then
        echo "检测到新版本，开始下载安装..."
        
        TMP_DIR=$(mktemp -d)
        trap 'rm -rf "$TMP_DIR"' EXIT

        RELEASE_ASSETS=$(
            echo "$RELEASE_JSON" |
            jq -r '.[]
                | select(.draft == false)
                | select(.prerelease == false)
                | select(
                    ((.tag_name // "") | ascii_downcase | contains("main"))
                    or ((.name // "") | ascii_downcase | contains("main"))
                )
                | .assets[]
                | select(.name | test("^linux-(image|headers)-.*arm64\\.deb$"))
                | [.name, .browser_download_url]
                | @tsv' |
            head -n2
        )

        IMAGE_URL=""
        HEADERS_URL=""

        while IFS=$'\t' read -r ASSET_NAME ASSET_URL; do
            case "$ASSET_NAME" in
                linux-image-*.deb) IMAGE_URL="$ASSET_URL" ;;
                linux-headers-*.deb) HEADERS_URL="$ASSET_URL" ;;
            esac
        done <<< "$RELEASE_ASSETS"

        [ -n "$IMAGE_URL" ] || die "找不到 image 包"
        [ -n "$HEADERS_URL" ] || die "找不到 headers 包"

        echo "下载 headers..."
        curl -fL "$HEADERS_URL" -o "$TMP_DIR/headers.deb" || die "下载失败"

        echo "下载 image..."
        curl -fL "$IMAGE_URL" -o "$TMP_DIR/image.deb" || die "下载失败"

        echo "安装..."
        dpkg -i "$TMP_DIR"/*.deb || {
            apt-get -f install -y || die "安装失败"
        }

        echo "安装完成"
        echo
    fi

fi

echo "[3/4] 更新 GRUB"

[ -f /etc/default/grub ] || die "找不到 /etc/default/grub"
[ -f /boot/grub/grub.cfg ] || die "找不到 /boot/grub/grub.cfg"

command -v update-grub >/dev/null 2>&1 || die "找不到 update-grub"
command -v grub-editenv >/dev/null 2>&1 || die "找不到 grub-editenv"

if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
else
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

update-grub >/dev/null 2>&1 || die "update-grub 失败"

echo "查找启动项..."

GRUB_TARGET=$(
grep "menuentry.*${INSTALLED_XANMOD}" /boot/grub/grub.cfg |
grep -v recovery |
head -n1 |
sed -n "s/.*--id[[:space:]]*'\([^']*\)'.*/\1/p"
)

if [ -z "$GRUB_TARGET" ]; then
    GRUB_TARGET=$(
    grep "menuentry.*${INSTALLED_XANMOD}" /boot/grub/grub.cfg |
    grep -v recovery |
    head -n1 |
    sed -n "s/.*'\([^']*\)'.*/\1/p"
    )
fi

[ -n "$GRUB_TARGET" ] || die "找不到启动项"

echo "启动项: $GRUB_TARGET"
echo

echo "[4/4] 设置默认启动"

rm -f /boot/grub/grubenv

grub-editenv /boot/grub/grubenv create || die "创建 grubenv 失败"

grub-editenv /boot/grub/grubenv set saved_entry="$GRUB_TARGET" || die "设置 saved_entry 失败"

VERIFY=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | grep "^saved_entry=" | cut -d= -f2)

if [ "$VERIFY" != "$GRUB_TARGET" ]; then
    die "设置验证失败 (期望: $GRUB_TARGET, 实际: $VERIFY)"
fi

echo "✓ 默认启动项已设置"
echo "✓ 下次启动将使用: ${INSTALLED_XANMOD}"
echo

if [ "$CURRENT_KERNEL" = "$INSTALLED_XANMOD" ]; then
    echo "当前已运行 XanMod，无需重启。"
    exit 0
fi

echo
read -r -p "现在重启？[y/N]: " CONFIRM
case "$CONFIRM" in
    y|Y) reboot ;;
    *) echo "已取消重启。" ;;
esac

