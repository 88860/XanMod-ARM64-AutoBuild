#!/bin/bash

set -u

REPO="88860/XanMod-ARM64-AutoBuild"
GRUB_CFG="/boot/grub/grub.cfg"
GRUB_DEFAULT_FILE="/etc/default/grub"

die() {
    echo
    echo "错误: $1"
    echo "操作已停止"
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行此脚本"
fi

for cmd in awk sed grep curl gzip dpkg apt-get update-grub find sort head; do
    command -v "$cmd" >/dev/null 2>&1 || die "未找到 $cmd"
done

[ -f /etc/os-release ] || die "无法读取 /etc/os-release"

. /etc/os-release

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
CURRENT_KERNEL=$(uname -r)

echo "========================================"
echo "XanMod MAIN 安装和升级"
echo "========================================"
echo
echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo

if [ "$ARCH" = "amd64" ]; then

    echo "架构类型: x86-64"

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
echo "检查在线 XanMod 版本"
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

    [ -n "$ONLINE_VERSION" ] ||
        die "无法获取 XanMod 在线版本"

    echo "在线软件包版本: ${ONLINE_VERSION}"
    echo "软件包: ${XANMOD_PKG}"

elif [ "$ARCH" = "arm64" ]; then

    if ! command -v jq >/dev/null 2>&1; then
        echo "正在安装 jq"
        apt-get update || die "apt-get update 失败"
        apt-get install -y jq || die "jq 安装失败"
    fi

    API_URL="https://api.github.com/repos/${REPO}/releases"

    RELEASE_JSON="$(
        curl -fsSL "$API_URL" 2>/dev/null
    )" || die "无法获取 XanMod ARM64 在线版本"

    RELEASE_TAG="$(
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
    )"

    [ -n "$RELEASE_TAG" ] ||
        die "无法找到 XanMod ARM64 MAIN 版本"

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
            echo "XanMod 已是最新版本"
            echo
        fi

    fi

elif [ "$ARCH" = "arm64" ] && [ -n "$INSTALLED_XANMOD" ]; then

    echo "当前 XanMod: ${INSTALLED_XANMOD}"
    echo "在线版本: ${ONLINE_VERSION}"
    echo

    if [[ "$INSTALLED_XANMOD" == *"$ONLINE_VERSION"* ]]; then
        echo "XanMod 已是在线版本"
        echo
    fi

fi

read -r -p "是否安装/升级 XanMod？[y/N]: " CONFIRM

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

if [ "$ARCH" = "amd64" ]; then

    mkdir -p /etc/apt/keyrings

    curl -fsSL \
        https://dl.xanmod.org/archive.key |
        gpg --dearmor \
        -o /etc/apt/keyrings/xanmod-archive-keyring.gpg ||
        die "XanMod 密钥安装失败"

    chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/xanmod.list <<EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main
EOF

    apt-get update ||
        die "apt-get update 失败"

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$XANMOD_PKG" ||
        die "XanMod 安装/升级失败"

elif [ "$ARCH" = "arm64" ]; then

    if ! command -v jq >/dev/null 2>&1; then
        apt-get update ||
            die "apt-get update 失败"

        apt-get install -y jq ||
            die "jq 安装失败"
    fi

    TMP_DIR="$(mktemp -d)"

    trap 'rm -rf "$TMP_DIR"' EXIT

    RELEASE_JSON="$(
        curl -fsSL \
        "https://api.github.com/repos/${REPO}/releases"
    )" || die "无法获取 GitHub Release"

    ASSETS="$(
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
    )"

    [ -n "$ASSETS" ] ||
        die "没有找到 ARM64 XanMod MAIN 安装包"

    while IFS= read -r URL; do

        [ -n "$URL" ] || continue

        FILE="$TMP_DIR/$(basename "$URL")"

        echo "下载: $(basename "$URL")"

        curl -fL "$URL" -o "$FILE" ||
            die "下载失败"

    done <<< "$ASSETS"

    echo
    echo "安装 ARM64 XanMod"

    dpkg -i "$TMP_DIR"/*.deb

    if [ $? -ne 0 ]; then

        echo
        echo "修复依赖"

        apt-get -f install -y ||
            die "ARM64 XanMod 安装失败"

    fi

fi

echo
echo "安装/升级完成"
echo

XANMOD_KERNEL="$(get_xanmod_kernel)"

[ -n "$XANMOD_KERNEL" ] ||
    die "无法找到 XanMod 内核"

echo "检测到 XanMod:"
echo "${XANMOD_KERNEL}"
echo

echo "更新 GRUB"

update-grub ||
    die "update-grub 执行失败"

[ -f "$GRUB_CFG" ] ||
    die "找不到 GRUB 配置"

command -v grub-set-default >/dev/null 2>&1 ||
    die "未找到 grub-set-default"

command -v grub-editenv >/dev/null 2>&1 ||
    die "未找到 grub-editenv"

echo
echo "定位 XanMod GRUB 启动项"

GRUB_TARGET="$(
awk -v target="$XANMOD_KERNEL" '
function get_id(line, s) {
    if (match(line, /\$menuentry_id_option[[:space:]]+'\''[^'\'']+'\''/)) {
        s=substr(line, RSTART, RLENGTH)
        sub(/^\$menuentry_id_option[[:space:]]+'\''/, "", s)
        sub(/'\''$/, "", s)
        return s
    }

    if (match(line, /--id[[:space:]]+'\''[^'\'']+'\''/)) {
        s=substr(line, RSTART, RLENGTH)
        sub(/^--id[[:space:]]+'\''/, "", s)
        sub(/'\''$/, "", s)
        return s
    }

    return ""
}

function count_char(s, c,    n, i) {
    n=0

    for (i=1; i<=length(s); i++) {
        if (substr(s,i,1) == c)
            n++
    }

    return n
}

{
    line=$0

    if (line ~ /^[[:space:]]*submenu[[:space:]]/) {
        id=get_id(line)

        if (id != "") {
            submenu_id=id
            submenu_depth=1
        }

        next
    }

    if (line ~ /^[[:space:]]*menuentry[[:space:]]/) {

        lower=tolower(line)

        if (
            index(lower, tolower(target)) > 0 &&
            index(lower, "recovery") == 0
        ) {

            id=get_id(line)

            if (id != "") {

                if (submenu_id != "")
                    print submenu_id ">" id
                else
                    print id

                exit
            }
        }
    }

    if (submenu_id != "") {

        opens=count_char(line, "{")
        closes=count_char(line, "}")

        submenu_depth += opens
        submenu_depth -= closes

        if (submenu_depth <= 0) {
            submenu_id=""
            submenu_depth=0
        }
    }
}
' "$GRUB_CFG"
)"

if [ -z "$GRUB_TARGET" ]; then

    GRUB_TARGET="$(
        grep "menuentry " "$GRUB_CFG" |
        grep "$XANMOD_KERNEL" |
        grep -vi "recovery" |
        sed -n "s/.*--id[[:space:]]*'\([^']*\)'.*/\1/p" |
        head -n1
    )"

fi

[ -n "$GRUB_TARGET" ] ||
    die "无法找到 XanMod GRUB 启动项"

echo "XanMod GRUB 启动项:"
echo "$GRUB_TARGET"
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

grub-set-default "$GRUB_TARGET" ||
    die "设置 GRUB 默认启动失败"

SAVED_ENTRY="$(
    grub-editenv list 2>/dev/null |
    sed -n 's/^saved_entry=//p'
)"

if [ "$SAVED_ENTRY" != "$GRUB_TARGET" ]; then

    echo
    echo "GRUB 默认项验证失败"
    echo "目标: $GRUB_TARGET"
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
echo "XanMod 内核: ${XANMOD_KERNEL}"
echo "GRUB 默认项: ${GRUB_TARGET}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo

read -r -p "是否现在重启系统？[y/N]: " REBOOT_CONFIRM

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "正在重启"
        reboot
        ;;
    *)
        echo
        echo "未重启系统"
        echo "下次启动将进入 XanMod"
        ;;
esac
