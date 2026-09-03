#!/bin/bash

set -u

die() {
    echo
    echo "✗ 错误: $1"
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"
}

require_root

for cmd in awk sed grep curl gzip dpkg dpkg-query; do
    command -v "$cmd" >/dev/null 2>&1 || die "未找到 $cmd"
done

echo "============================================"
echo "      XanMod MAIN 安装和升级"
echo "============================================"
echo

[ -f /etc/os-release ] || die "无法读取 /etc/os-release"
. /etc/os-release

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
CURRENT_KERNEL=$(uname -r)

echo "[1/6] 系统检测"
echo
echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前内核: ${CURRENT_KERNEL}"
echo

if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "amd64" ]; then
    die "不支持的架构: ${ARCH}"
fi

echo "检测已安装的内核..."
INSTALLED_XANMOD=""
for kernel_dir in /lib/modules/*; do
    [ -d "$kernel_dir" ] || continue
    kernel_name=$(basename "$kernel_dir")
    if [[ "$kernel_name" == *xanmod* ]]; then
        INSTALLED_XANMOD="$kernel_name"
        break
    fi
done

INSTALLED_JOEY=""
for pkg_name in $(dpkg -l | grep "linux-image.*joeyblog" | awk '{print $2}'); do
    if dpkg -l | grep -q "^ii.*$pkg_name"; then
        INSTALLED_JOEY="$pkg_name"
        break
    fi
done

if [ -z "$INSTALLED_XANMOD" ]; then
    echo "✗ 未找到已安装的 XanMod 内核"
    echo
    read -r -p "是否现在安装 XanMod MAIN？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y) INSTALL_NEW=1 ;;
        *) echo "已取消。"; exit 0 ;;
    esac
    INSTALLED_XANMOD="unknown"
else
    echo "✓ XanMod 内核: ${INSTALLED_XANMOD}"
fi

if [ -n "$INSTALLED_JOEY" ]; then
    echo "⚠ 检测到 Joey 内核: ${INSTALLED_JOEY}"
    echo
    echo "注意：您同时安装了 XanMod 和 Joey 内核。"
    echo "为确保 XanMod 正确启动，建议卸载 Joey 内核。"
    echo
    read -r -p "是否卸载 Joey 内核？[y/N]: " REMOVE_JOEY
    case "$REMOVE_JOEY" in
        y|Y)
            echo "卸载 Joey 内核..."
            PACKAGES_TO_REMOVE=$(dpkg -l | grep "linux.*joeyblog" | awk '{print $2}' | tr '\n' ' ')
            if [ -n "$PACKAGES_TO_REMOVE" ]; then
                sudo apt-get remove --purge $PACKAGES_TO_REMOVE -y > /dev/null 2>&1 || echo "⚠ 卸载过程中可能出现错误"
                echo "✓ Joey 内核已卸载"
                INSTALLED_JOEY=""
            fi
            ;;
        *)
            echo "⚠ 已跳过卸载，您需要手动处理或接受 Joey 内核可能优先启动的风险"
            ;;
    esac
fi

echo

echo "[2/6] 版本检测"
echo

if [ "$ARCH" = "arm64" ]; then

    command -v jq >/dev/null 2>&1 || die "需要安装 jq"

    echo "获取在线版本..."
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
    
    if [ "$INSTALLED_XANMOD" != "unknown" ]; then
        echo "已安装版本: ${INSTALLED_XANMOD}"
        
        INSTALLED_VER=$(echo "$INSTALLED_XANMOD" | sed 's/-arm64-main$//')
        
        if [ "$INSTALLED_VER" = "$ONLINE_VERSION" ]; then
            echo
            echo "✓ XanMod MAIN 已经是最新版本"
            NEED_UPDATE=0
        else
            echo
            echo "✗ 检测到新版本"
            NEED_UPDATE=1
        fi
    else
        NEED_UPDATE=1
    fi

elif [ "$ARCH" = "amd64" ]; then

    command -v gpg >/dev/null 2>&1 || die "需要安装 gpg"

    if /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v3 (supported, searched)'; then
        XANMOD_VER="x86-64-v3"
        XANMOD_PKG="linux-xanmod-x64v3"
    elif /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v2 (supported, searched)'; then
        XANMOD_VER="x86-64-v2"
        XANMOD_PKG="linux-xanmod-x64v2"
    else
        die "当前 CPU 不支持 XanMod x86-64-v2/v3"
    fi

    echo "CPU 兼容级别: ${XANMOD_VER}"
    
    XANMOD_REPO_URL="http://deb.xanmod.org/dists/${VERSION_CODENAME}/main/binary-amd64/Packages.gz"

    ONLINE_VERSION=$(
        curl -fsSL "$XANMOD_REPO_URL" 2>/dev/null |
        gzip -dc 2>/dev/null |
        awk -v pkg="$XANMOD_PKG" '
            $1 == "Package:" && $2 == pkg { found=1 }
            found && $1 == "Version:" { print $2; exit }
        '
    )

    [ -n "$ONLINE_VERSION" ] || die "无法获取在线版本"

    echo "在线版本: ${ONLINE_VERSION}"
    
    if [ "$INSTALLED_XANMOD" != "unknown" ]; then
        INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$XANMOD_PKG" 2>/dev/null || true)
        echo "已安装版本: ${INSTALLED_VER}"
        
        if [ -n "$INSTALLED_VER" ] && dpkg --compare-versions "$INSTALLED_VER" ge "$ONLINE_VERSION"; then
            echo
            echo "✓ XanMod MAIN 已经是最新版本"
            NEED_UPDATE=0
        else
            echo
            echo "✗ 检测到新版本"
            NEED_UPDATE=1
        fi
    else
        NEED_UPDATE=1
    fi

fi

echo

if [ "$NEED_UPDATE" -eq 1 ]; then
    read -r -p "是否更新 XanMod MAIN？[y/N]: " CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *) echo "已取消。"; exit 0 ;;
    esac
fi

echo

if [ "$NEED_UPDATE" -eq 1 ]; then
    echo "[3/6] 更新 XanMod"
    echo

    if [ "$ARCH" = "arm64" ]; then

        TMP_DIR=$(mktemp -d)
        trap 'rm -rf "$TMP_DIR"' EXIT

        echo "获取下载链接..."

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
            echo "修复依赖..."
            apt-get -f install -y || die "安装失败"
        }

        echo "✓ 安装完成"
        
        INSTALLED_XANMOD=""
        for kernel_dir in /lib/modules/*; do
            [ -d "$kernel_dir" ] || continue
            kernel_name=$(basename "$kernel_dir")
            if [[ "$kernel_name" == *xanmod* ]]; then
                INSTALLED_XANMOD="$kernel_name"
                break
            fi
        done

    elif [ "$ARCH" = "amd64" ]; then

        mkdir -p /etc/apt/keyrings

        curl -fsSL https://dl.xanmod.org/archive.key |
            gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg ||
            die "XanMod 密钥安装失败"

        chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

        cat > /etc/apt/sources.list.d/xanmod.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main
EOF

        apt-get update || die "apt-get update 失败"

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "$XANMOD_PKG" ||
            die "XanMod 安装失败"

        echo "✓ 安装完成"

        INSTALLED_XANMOD=""
        for kernel_dir in /lib/modules/*; do
            [ -d "$kernel_dir" ] || continue
            kernel_name=$(basename "$kernel_dir")
            if [[ "$kernel_name" == *xanmod* ]]; then
                INSTALLED_XANMOD="$kernel_name"
                break
            fi
        done

    fi

    echo

else
    echo "[3/6] 跳过更新"
    echo
fi

echo "[4/6] 更新 GRUB 配置"
echo

[ -f /etc/default/grub ] || die "找不到 /etc/default/grub"
[ -f /boot/grub/grub.cfg ] || die "找不到 /boot/grub/grub.cfg"

command -v update-grub >/dev/null 2>&1 || die "找不到 update-grub"

echo "运行 update-grub..."
update-grub >/dev/null 2>&1 || die "update-grub 失败"

echo "[5/6] 设置 XanMod 启动项"
echo

echo "查找 XanMod 启动项..."

XANMOD_ID=$(
grep "menuentry.*xanmod" /boot/grub/grub.cfg |
grep -v recovery |
head -n1 |
sed -n "s/.*--id[[:space:]]*'\([^']*\)'.*/\1/p"
)

if [ -z "$XANMOD_ID" ]; then
    XANMOD_ID=$(
    grep "menuentry.*xanmod" /boot/grub/grub.cfg |
    grep -v recovery |
    head -n1 |
    sed -n "s/.*'\([^']*\)'.*/\1/p"
    )
fi

[ -n "$XANMOD_ID" ] || die "找不到 XanMod 启动项"

echo "启动项 ID: $XANMOD_ID"

echo "设置 GRUB_DEFAULT..."

if grep -q "^GRUB_DEFAULT=" /etc/default/grub; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT='${XANMOD_ID}'|" /etc/default/grub
else
    echo "GRUB_DEFAULT='${XANMOD_ID}'" >> /etc/default/grub
fi

update-grub >/dev/null 2>&1 || die "update-grub 失败"

echo "✓ GRUB 启动项已配置"
echo

GRUB_SETTING=$(grep "^GRUB_DEFAULT=" /etc/default/grub)
echo "配置验证: $GRUB_SETTING"

echo

echo "[6/6] 验证配置"
echo

XANMOD_COUNT=$(grep -c "menuentry.*xanmod" /boot/grub/grub.cfg || true)
echo "检测到 $XANMOD_COUNT 个 XanMod 启动项"

if [ -n "$INSTALLED_JOEY" ]; then
    JOEY_COUNT=$(grep -c "menuentry.*joeyblog" /boot/grub/grub.cfg || true)
    echo "检测到 $JOEY_COUNT 个 Joey 启动项"
fi

echo
echo "目标内核: ${INSTALLED_XANMOD}"
echo "当前内核: ${CURRENT_KERNEL}"
echo

if [ "$CURRENT_KERNEL" = "$INSTALLED_XANMOD" ]; then
    echo "✓ 当前已运行 XanMod，无需重启。"
    echo
    echo "但如果您之前卸载了 Joey 内核，仍需重启以清理旧启动项。"
    read -r -p "是否重启？[y/N]: " REBOOT_CONFIRM
else
    echo "需要重启才能启动 XanMod 内核。"
    echo
    read -r -p "是否现在重启系统？[y/N]: " REBOOT_CONFIRM
fi

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "正在重启..."
        sleep 2
        reboot
        ;;
    *)
        echo
        echo "已取消重启。"
        if [ "$CURRENT_KERNEL" != "$INSTALLED_XANMOD" ]; then
            echo "下次启动将使用 XanMod 内核。"
        fi
        echo
        echo "后续更新 XanMod 内核时，直接运行此脚本即可。"
        ;;
esac

