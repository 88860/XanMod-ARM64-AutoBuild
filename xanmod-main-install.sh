#!/bin/bash

set -e

apt update
apt install -y wget curl gpg ca-certificates jq grub-common grub2-common

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)

die() {
    echo "ERROR: $1"
    exit 1
}

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

if [ "$ARCH" = "amd64" ]; then
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
elif [ "$ARCH" = "arm64" ]; then
    XANMOD_VER="ARM64"
    XANMOD_PKG=""
else
    die "Unsupported architecture: $ARCH"
fi

echo "Detected architecture: $ARCH"
echo "Detected XanMod: $XANMOD_VER"

ONLINE_VERSION=""
INSTALLED_VERSION=""
NEED_INSTALL=1

if [ "$ARCH" = "amd64" ]; then
    if [ "$XANMOD_VER" = "x86-64-v1" ]; then
        die "XanMod MAIN does not provide x86-64-v1"
    fi

    install -d -m 0755 /etc/apt/keyrings

    wget -qO - https://dl.xanmod.org/archive.key |
        gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg

    chmod 0644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

    . /etc/os-release

    printf '%s\n' \
        "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/xanmod-release.list

    apt update

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

    [ -n "$ONLINE_VERSION" ] || die "无法获取 XanMod 在线版本"

    if dpkg-query -W -f='${Status}' "$XANMOD_PKG" 2>/dev/null |
        grep -q "install ok installed"; then
        INSTALLED_VERSION=$(dpkg-query -W -f='${Version}' "$XANMOD_PKG" 2>/dev/null)
    fi

    echo "Installed version: ${INSTALLED_VERSION:-未安装}"
    echo "Online version:    $ONLINE_VERSION"

    if [ -n "$INSTALLED_VERSION" ] &&
       [ "$INSTALLED_VERSION" = "$ONLINE_VERSION" ]; then
        echo "XanMod 已是最新版本"
        NEED_INSTALL=0
    fi

elif [ "$ARCH" = "arm64" ]; then
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    API_URL="https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases?per_page=100"

    RELEASE_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) ||
        die "无法获取 ARM64 XanMod Release"

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

    [ -n "$RELEASE_TAG" ] || die "没有找到 ARM64 MAIN Release"

    ONLINE_VERSION="$RELEASE_TAG"

    INSTALLED_XANMOD=$(get_xanmod_kernel)

    if [ -n "$INSTALLED_XANMOD" ]; then
        INSTALLED_VERSION="${INSTALLED_XANMOD%-arm64-main}"
    fi

    echo "Installed version: ${INSTALLED_VERSION:-未安装}"
    echo "Online version:    $ONLINE_VERSION"

    if [ -n "$INSTALLED_VERSION" ] &&
       [ "$INSTALLED_VERSION" = "$ONLINE_VERSION" ]; then
        echo "XanMod 已是最新版本"
        NEED_INSTALL=0
    fi
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    echo "检测到需要安装或升级 XanMod"

    read -r -p "是否继续？[y/N]: " CONFIRM

    case "$CONFIRM" in
        y|Y)
            ;;
        *)
            echo "已取消"
            exit 0
            ;;
    esac

    if [ "$ARCH" = "amd64" ]; then
        echo "Installing MAIN: $XANMOD_PKG"
        apt install -y "$XANMOD_PKG"

    elif [ "$ARCH" = "arm64" ]; then
        echo "Selected MAIN release: $RELEASE_TAG"

        curl -fsSL \
            "https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases/tags/$RELEASE_TAG" |
            jq -r '
                .assets[]
                | select(.name | test("^linux-(image|headers)-.*arm64\\.deb$"))
                | .browser_download_url
            ' |
            wget -q -i- -P "$TMPDIR"

        ls "$TMPDIR"/linux-image-*_arm64.deb >/dev/null 2>&1 ||
            die "ARM64 MAIN image package not found"

        ls "$TMPDIR"/linux-headers-*_arm64.deb >/dev/null 2>&1 ||
            die "ARM64 MAIN headers package not found"

        apt install -y "$TMPDIR"/*.deb
    fi
else
    echo "无需安装或升级"
    echo "直接进入 GRUB 配置"
fi

update-grub || die "update-grub 失败"

XANMOD_KERNEL=$(get_xanmod_kernel)

[ -n "$XANMOD_KERNEL" ] ||
    die "XanMod kernel not found"

GRUB_CFG="/boot/grub/grub.cfg"
GRUB_DEFAULT_FILE="/etc/default/grub"

[ -f "$GRUB_CFG" ] ||
    die "GRUB configuration not found"

XANMOD_GRUB_ID=$(awk -v k="vmlinuz-${XANMOD_KERNEL}" '
    /^[[:space:]]*submenu[[:space:]]/ {
        for(i=1; i<=NF; i++) {
            if($i ~ /id_option$/ || $i == "--id") {
                id = $(i+1)
                gsub(/'\''/, "", id)
                sub_id = id
            }
        }
    }
    /^[[:space:]]*menuentry[[:space:]]/ {
        m_id = ""
        for(i=1; i<=NF; i++) {
            if($i ~ /id_option$/ || $i == "--id") {
                id = $(i+1)
                gsub(/'\''/, "", id)
                m_id = id
            }
        }
        if ($0 ~ /recovery/) {
            m_id = ""
        }
    }
    $0 ~ k && m_id != "" {
        if (sub_id != "") {
            print sub_id ">" m_id
        } else {
            print m_id
        }
        exit
    }
' "$GRUB_CFG")

[ -n "$XANMOD_GRUB_ID" ] ||
    die "XanMod GRUB entry not found"

if grep -q '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$GRUB_DEFAULT_FILE"
else
    printf '%s\n' 'GRUB_DEFAULT=saved' >> "$GRUB_DEFAULT_FILE"
fi

if grep -q '^GRUB_SAVEDEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=false/' "$GRUB_DEFAULT_FILE"
else
    printf '%s\n' 'GRUB_SAVEDEFAULT=false' >> "$GRUB_DEFAULT_FILE"
fi

grub-set-default "$XANMOD_GRUB_ID" ||
    die "设置 GRUB 默认启动项失败"

SAVED_ENTRY=$(
    grub-editenv /boot/grub/grubenv list 2>/dev/null |
    sed -n 's/^saved_entry=//p'
)

[ "$SAVED_ENTRY" = "$XANMOD_GRUB_ID" ] ||
    die "GRUB 默认启动项验证失败"

update-grub || die "最终 update-grub 失败"

echo "XanMod: $XANMOD_KERNEL"
echo "GRUB: $XANMOD_GRUB_ID"
echo "完成，系统即将重启"

reboot

