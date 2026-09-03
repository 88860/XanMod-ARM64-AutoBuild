#!/bin/bash

set -u

REPO="88860/XanMod-ARM64-AutoBuild"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_DEFAULT_FILE="/etc/default/grub"

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行"
    exit 1
fi

for cmd in curl wget dpkg apt-get update-grub awk grep sed sort head find gpg; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少命令: $cmd"
        exit 1
    fi
done

ARCH="$(dpkg --print-architecture)"
CURRENT_KERNEL="$(uname -r)"

echo "当前架构: $ARCH"
echo "当前内核: $CURRENT_KERNEL"

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
    echo "已安装 XanMod: $INSTALLED_XANMOD"
else
    echo "未检测到 XanMod"
fi

if [ "$ARCH" = "arm64" ]; then

    echo "开始检查 ARM64 XanMod"

    if ! command -v jq >/dev/null 2>&1; then
        echo "正在安装 jq"
        apt-get update
        apt-get install -y jq
    fi

    RELEASES="$(
        curl -fsSL \
        "https://api.github.com/repos/${REPO}/releases"
    )"

    LATEST_RELEASE="$(
        echo "$RELEASES" |
        jq -r '
            .[]
            | select(.draft == false)
            | select(.prerelease == false)
            | select(
                ((.tag_name // "") | test("main"; "i"))
                or
                ((.name // "") | test("main"; "i"))
              )
            | .tag_name
        ' |
        head -n1
    )"

    if [ -z "$LATEST_RELEASE" ] || [ "$LATEST_RELEASE" = "null" ]; then
        echo "无法获取 ARM64 XanMod 最新版本"
        exit 1
    fi

    echo "最新版本: $LATEST_RELEASE"

    INSTALLED_VERSION="${INSTALLED_XANMOD%-arm64-main}"

    if [ -n "$INSTALLED_XANMOD" ] &&
       [ "$INSTALLED_VERSION" = "$LATEST_RELEASE" ]; then

        echo "ARM64 XanMod 已是最新版本"

    else

        echo "准备安装: $LATEST_RELEASE"

        RELEASE_JSON="$(
            curl -fsSL \
            "https://api.github.com/repos/${REPO}/releases/tags/${LATEST_RELEASE}"
        )"

        IMAGE_URL="$(
            echo "$RELEASE_JSON" |
            jq -r '
                .assets[]
                | select(
                    .name | test("^linux-image-.*arm64\\.deb$")
                  )
                | .browser_download_url
            ' |
            head -n1
        )"

        HEADERS_URL="$(
            echo "$RELEASE_JSON" |
            jq -r '
                .assets[]
                | select(
                    .name | test("^linux-headers-.*arm64\\.deb$")
                  )
                | .browser_download_url
            ' |
            head -n1
        )"

        if [ -z "$IMAGE_URL" ] || [ "$IMAGE_URL" = "null" ]; then
            echo "找不到 ARM64 linux-image 安装包"
            exit 1
        fi

        mkdir -p /tmp/xanmod-install
        rm -f /tmp/xanmod-install/*.deb

        echo "下载 XanMod 内核"

        wget -q --show-progress \
            "$IMAGE_URL" \
            -O /tmp/xanmod-install/linux-image.deb

        if [ -n "$HEADERS_URL" ] &&
           [ "$HEADERS_URL" != "null" ]; then

            wget -q --show-progress \
                "$HEADERS_URL" \
                -O /tmp/xanmod-install/linux-headers.deb
        fi

        echo "安装 ARM64 XanMod"

        if ! dpkg -i /tmp/xanmod-install/*.deb; then
            echo "正在修复依赖"
            apt-get -f install -y
        fi

        rm -rf /tmp/xanmod-install
    fi

elif [ "$ARCH" = "amd64" ]; then

    echo "开始检查 amd64 XanMod"

    if [ -x /lib64/ld-linux-x86-64.so.2 ]; then

        if /lib64/ld-linux-x86-64.so.2 --help 2>/dev/null |
            grep -q 'x86-64-v3'; then
            CPU_LEVEL="v3"
        else
            CPU_LEVEL="v2"
        fi

    else
        CPU_LEVEL="v2"
    fi

    if [ "$CPU_LEVEL" = "v3" ]; then
        XANMOD_PKG="linux-xanmod-x64v3"
    else
        XANMOD_PKG="linux-xanmod-x64v2"
    fi

    echo "CPU 优化级别: x86-64-$CPU_LEVEL"
    echo "APT 软件包: $XANMOD_PKG"

    . /etc/os-release

    if [ -z "${VERSION_CODENAME:-}" ]; then
        echo "无法确定系统版本代号"
        exit 1
    fi

    CODENAME="$VERSION_CODENAME"

    echo "系统版本: $CODENAME"

    mkdir -p /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ]; then

        echo "安装 XanMod 软件源密钥"

        wget -qO- \
            https://dl.xanmod.org/archive.key |
            gpg --dearmor \
            -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
    fi

    cat > /etc/apt/sources.list.d/xanmod.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${CODENAME} main
EOF

    echo "更新 XanMod 软件源"

    apt-get update

    echo "安装/升级 XanMod"

    apt-get install -y "$XANMOD_PKG"

else

    echo "不支持的架构: $ARCH"
    exit 1
fi

INSTALLED_XANMOD="$(get_xanmod_kernel)"

if [ -z "$INSTALLED_XANMOD" ]; then
    echo "安装后没有找到 XanMod 内核"
    exit 1
fi

echo "XanMod 内核: $INSTALLED_XANMOD"

echo "更新 GRUB"

update-grub

if [ ! -f "$GRUB_CFG" ]; then
    echo "找不到 GRUB 配置"
    exit 1
fi

XANMOD_GRUB_PATH=""

MENU_ID=""
MENU_DEPTH=0
SUBMENU_ID=""

while IFS= read -r line; do

    OPEN_COUNT="$(
        printf '%s\n' "$line" |
        tr -cd '{' |
        wc -c
    )"

    CLOSE_COUNT="$(
        printf '%s\n' "$line" |
        tr -cd '}' |
        wc -c
    )"

    if printf '%s\n' "$line" |
        grep -qE '^[[:space:]]*submenu '; then

        SUBMENU_ID="$(
            printf '%s\n' "$line" |
            sed -n "s/.*--id[[:space:]]*'\\([^']*\\)'.*/\\1/p"
        )

        MENU_DEPTH=$((MENU_DEPTH + OPEN_COUNT - CLOSE_COUNT))
        continue
    fi

    if printf '%s\n' "$line" |
        grep -q "menuentry "; then

        if printf '%s\n' "$line" |
            grep -q "Linux ${INSTALLED_XANMOD}" &&
            ! printf '%s\n' "$line" |
            grep -q "recovery mode"; then

            MENU_ID="$(
                printf '%s\n' "$line" |
                sed -n "s/.*--id[[:space:]]*'\\([^']*\\)'.*/\\1/p"
            )"

            if [ -n "$MENU_ID" ]; then

                if [ -n "$SUBMENU_ID" ]; then
                    XANMOD_GRUB_PATH="${SUBMENU_ID}>${MENU_ID}"
                else
                    XANMOD_GRUB_PATH="$MENU_ID"
                fi

                break
            fi
        fi
    fi

    MENU_DEPTH=$((MENU_DEPTH + OPEN_COUNT - CLOSE_COUNT))

    if [ "$MENU_DEPTH" -le 0 ]; then
        SUBMENU_ID=""
        MENU_DEPTH=0
    fi

done < "$GRUB_CFG"

if [ -z "$XANMOD_GRUB_PATH" ]; then

    XANMOD_GRUB_PATH="$(
        grep "menuentry " "$GRUB_CFG" |
        grep "Linux ${INSTALLED_XANMOD}" |
        grep -v "recovery mode" |
        sed -n "s/.*--id[[:space:]]*'\\([^']*\\)'.*/\\1/p" |
        head -n1
    )"

fi

if [ -z "$XANMOD_GRUB_PATH" ]; then
    echo "无法定位 XanMod 的 GRUB 启动项"
    exit 1
fi

echo "XanMod GRUB 启动项: $XANMOD_GRUB_PATH"

if grep -q '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
        "$GRUB_DEFAULT_FILE"
else
    echo 'GRUB_DEFAULT=saved' >> "$GRUB_DEFAULT_FILE"
fi

if grep -q '^GRUB_SAVEDEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=false/' \
        "$GRUB_DEFAULT_FILE"
else
    echo 'GRUB_SAVEDEFAULT=false' >> "$GRUB_DEFAULT_FILE"
fi

if command -v grub-set-default >/dev/null 2>&1; then

    grub-set-default "$XANMOD_GRUB_PATH"

else

    if command -v grub-editenv >/dev/null 2>&1; then

        grub-editenv /boot/grub/grubenv \
            set "saved_entry=$XANMOD_GRUB_PATH"

    else

        echo "无法设置 GRUB 默认启动项"
        exit 1
    fi
fi

update-grub

echo
echo "=============================="
echo "XanMod 配置完成"
echo "=============================="
echo "XanMod: $INSTALLED_XANMOD"
echo "GRUB 默认项: $XANMOD_GRUB_PATH"
echo

if command -v grub-editenv >/dev/null 2>&1; then
    grub-editenv /boot/grub/grubenv list 2>/dev/null || true
fi

echo
echo "已安装 XanMod:"
find /lib/modules \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%f\n' 2>/dev/null |
    grep -i 'xanmod' |
    sort -V

echo
echo "下次启动将默认进入 XanMod"
echo "其他内核不会被处理"
echo

read -r -p "现在重启吗？[y/N]: " REBOOT

if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    reboot
fi
