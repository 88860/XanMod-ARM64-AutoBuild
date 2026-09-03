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

for cmd in awk sed grep curl gzip dpkg dpkg-query; do
    command -v "$cmd" >/dev/null 2>&1 || die "未找到 $cmd"
done

echo "========================================"
echo "      ${SCRIPT_NAME}"
echo "========================================"
echo

[ -f /etc/os-release ] || die "无法读取 /etc/os-release"
. /etc/os-release

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
CURRENT_KERNEL=$(uname -r)

echo "[1/5] 检测系统信息"
echo
echo "系统: ${PRETTY_NAME:-未知}"
echo "架构: ${ARCH}"
echo "当前运行内核: ${CURRENT_KERNEL}"
echo

if [ "$ARCH" = "amd64" ]; then

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

    echo "CPU 兼容级别: ${XANMOD_VER}"

    [ -n "$XANMOD_PKG" ] ||
        die "当前 CPU 不支持 XanMod x86-64-v2/v3"

    echo "XanMod 适配版本: ${XANMOD_PKG}"

elif [ "$ARCH" = "arm64" ]; then

    echo "架构类型: ARM64"

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
    echo "已安装 XanMod 内核: ${INSTALLED_XANMOD}"
else
    echo "已安装 XanMod 内核: 未安装"
fi

echo
echo "[2/5] 检测在线 XanMod MAIN 版本"
echo

ONLINE_VERSION=""

if [ "$ARCH" = "amd64" ]; then

    command -v gpg >/dev/null 2>&1 ||
        die "未找到 gpg"

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
        die "无法获取 XanMod MAIN 在线版本"

    echo "在线软件包版本: ${ONLINE_VERSION}"
    echo "软件包: ${XANMOD_PKG}"

elif [ "$ARCH" = "arm64" ]; then

    command -v jq >/dev/null 2>&1 ||
        die "ARM64 版本检测需要 jq，请先安装 jq"

    API_URL="https://api.github.com/repos/88860/XanMod-ARM64-AutoBuild/releases"

    RELEASE_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) ||
        die "无法获取 XanMod ARM64 在线版本"

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

    [ -n "$RELEASE_TAG" ] ||
        die "无法找到 XanMod ARM64 MAIN 版本"

    ONLINE_VERSION="$RELEASE_TAG"

    echo "在线版本: ${ONLINE_VERSION}"

fi

echo

ACTION=""

if [ -z "$INSTALLED_XANMOD" ]; then

    ACTION="安装"

    echo "未检测到已安装的 XanMod MAIN 内核。"
    echo
    read -r -p "是否安装 XanMod MAIN？[y/N]: " CONFIRM

    case "$CONFIRM" in
        y|Y) ;;
        *) echo "已取消。"; exit 0 ;;
    esac

else

    if [ "$ARCH" = "amd64" ]; then

        INSTALLED_VERSION=$(
            dpkg-query -W -f='${Version}' "$XANMOD_PKG" 2>/dev/null || true
        )

        [ -n "$INSTALLED_VERSION" ] ||
            die "无法获取已安装 XanMod 软件包版本"

        echo "当前软件包版本: ${INSTALLED_VERSION}"
        echo "在线软件包版本: ${ONLINE_VERSION}"
        echo

        if dpkg --compare-versions "$INSTALLED_VERSION" lt "$ONLINE_VERSION"; then

            ACTION="升级"

            echo "检测到 XanMod MAIN 新版本。"
            echo
            read -r -p "是否升级 XanMod MAIN？[y/N]: " CONFIRM

            case "$CONFIRM" in
                y|Y) ;;
                *) echo "已取消。"; exit 0 ;;
            esac

        elif dpkg --compare-versions "$INSTALLED_VERSION" gt "$ONLINE_VERSION"; then

            echo "当前安装版本高于在线版本。"
            ACTION="检查"

        else

            echo "XanMod MAIN 已经是最新版本。"

            if [ "$CURRENT_KERNEL" = "$INSTALLED_XANMOD" ]; then
                echo
                echo "当前运行的就是目标 XanMod 内核。"
                echo
                echo "无需安装、升级或修改 GRUB。"
                exit 0
            fi

            echo
            echo "当前运行内核不是目标 XanMod："
            echo "当前运行: ${CURRENT_KERNEL}"
            echo "目标内核: ${INSTALLED_XANMOD}"
            echo
            echo "将设置 XanMod 为 GRUB 默认启动内核。"

            ACTION="设置默认启动"

        fi

    elif [ "$ARCH" = "arm64" ]; then

        INSTALLED_VERSION="${INSTALLED_XANMOD}"

        case "$INSTALLED_VERSION" in
            *-arm64-main)
                INSTALLED_VERSION="${INSTALLED_VERSION%-arm64-main}"
                ;;
        esac

        echo "当前 XanMod 版本: ${INSTALLED_VERSION}"
        echo "在线 XanMod 版本: ${ONLINE_VERSION}"
        echo

        if [ "$INSTALLED_VERSION" != "$ONLINE_VERSION" ]; then

            ACTION="升级"

            echo "检测到 XanMod MAIN 新版本。"
            echo
            read -r -p "是否升级 XanMod MAIN？[y/N]: " CONFIRM

            case "$CONFIRM" in
                y|Y) ;;
                *) echo "已取消。"; exit 0 ;;
            esac

        else

            echo "XanMod MAIN 已经是最新版本。"

            if [ "$CURRENT_KERNEL" = "$INSTALLED_XANMOD" ]; then
                echo
                echo "当前运行的就是目标 XanMod 内核。"
                echo
                echo "无需安装、升级或修改 GRUB。"
                exit 0
            fi

            echo
            echo "当前运行内核不是目标 XanMod："
            echo "当前运行: ${CURRENT_KERNEL}"
            echo "目标内核: ${INSTALLED_XANMOD}"
            echo
            echo "将设置 XanMod 为 GRUB 默认启动内核。"

            ACTION="设置默认启动"

        fi

    fi

fi

echo

if [ "$ACTION" = "设置默认启动" ]; then
    echo "[3/5] 跳过安装/升级"
    echo
else
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

        RELEASE_ASSETS=$(
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
                | [.name, .browser_download_url]
                | @tsv
            ' |
            head -n2
        )

        IMAGE_URL=""
        HEADERS_URL=""

        while IFS=$'\t' read -r ASSET_NAME ASSET_URL; do

            case "$ASSET_NAME" in
                linux-image-*.deb)
                    IMAGE_URL="$ASSET_URL"
                    ;;
                linux-headers-*.deb)
                    HEADERS_URL="$ASSET_URL"
                    ;;
            esac

        done <<< "$RELEASE_ASSETS"

        [ -n "$IMAGE_URL" ] ||
            die "没有找到 ARM64 XanMod MAIN image 安装包"

        [ -n "$HEADERS_URL" ] ||
            die "没有找到 ARM64 XanMod MAIN headers 安装包"

        for URL in "$HEADERS_URL" "$IMAGE_URL"; do

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

fi

echo
echo "检测实际 XanMod 内核..."

XANMOD_KERNEL=""

for kernel_dir in /lib/modules/*; do

    [ -d "$kernel_dir" ] || continue

    kernel_name=$(basename "$kernel_dir")

    if [[ "$kernel_name" == *xanmod* ]]; then

        if [ -z "$XANMOD_KERNEL" ]; then
            XANMOD_KERNEL="$kernel_name"
        fi

    fi

done

[ -n "$XANMOD_KERNEL" ] ||
    die "无法找到实际 XanMod 内核"

if [ "$ACTION" != "设置默认启动" ] &&
   [ "$ACTION" != "检查" ]; then

    echo
    echo "XanMod ${ACTION}成功。"

fi

echo
echo "检测到 XanMod 内核:"

for kernel_dir in /lib/modules/*xanmod*; do
    [ -d "$kernel_dir" ] || continue
    basename "$kernel_dir"
done

echo

if [ "$CURRENT_KERNEL" = "$XANMOD_KERNEL" ]; then

    echo "当前运行内核已经是 XanMod：${CURRENT_KERNEL}"
    echo
    echo "无需修改 GRUB。"
    exit 0

fi

echo "[4/5] 设置 XanMod 为默认启动内核"
echo

command -v update-grub >/dev/null 2>&1 ||
    die "未找到 update-grub"

command -v grub-set-default >/dev/null 2>&1 ||
    die "未找到 grub-set-default"

command -v grub-editenv >/dev/null 2>&1 ||
    die "未找到 grub-editenv"

[ -f /boot/grub/grub.cfg ] ||
    die "找不到 /boot/grub/grub.cfg"

if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
else
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

update-grub ||
    die "update-grub 执行失败"

echo
echo "正在搜索 XanMod GRUB 启动项..."

GRUB_TARGET=$(
awk -v target="$XANMOD_KERNEL" '
function extract_id(line, id) {
    id=""

    if (match(line, /\$menuentry_id_option[[:space:]]+\047[^\047]+\047/)) {
        id=substr(line, RSTART, RLENGTH)
        sub(/^\$menuentry_id_option[[:space:]]+\047/, "", id)
        sub(/\047$/, "", id)
        return id
    }

    if (match(line, /--id[[:space:]]+\047[^\047]+\047/)) {
        id=substr(line, RSTART, RLENGTH)
        sub(/^--id[[:space:]]+\047/, "", id)
        sub(/\047$/, "", id)
        return id
    }

    return ""
}

function count_open(line, t) {
    t=line
    return gsub(/\{/, "", t)
}

function count_close(line, t) {
    t=line
    return gsub(/\}/, "", t)
}

{
    line=$0

    if (line ~ /^[[:space:]]*submenu[[:space:]]/) {

        sid=extract_id(line)

        if (sid != "") {
            submenu_id=sid
            submenu_depth=depth
        }
    }

    if (line ~ /^[[:space:]]*menuentry[[:space:]]/) {

        entry_id=extract_id(line)

        if (
            entry_id != "" &&
            index(tolower(line), tolower(target)) > 0 &&
            index(tolower(line), "recovery") == 0
        ) {

            if (submenu_id != "" && depth > submenu_depth) {
                print submenu_id ">" entry_id
            } else {
                print entry_id
            }

            exit
        }
    }

    depth += count_open(line)
    depth -= count_close(line)

    if (submenu_id != "" && depth <= submenu_depth) {
        submenu_id=""
    }
}
' /boot/grub/grub.cfg
)

[ -n "$GRUB_TARGET" ] ||
    die "无法找到目标 XanMod GRUB 启动项"

echo
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
echo "目标内核: ${XANMOD_KERNEL}"
echo
echo "注意：这里只验证 GRUB 默认启动项。"
echo "重启后的实际运行内核请使用 uname -r 确认。"

echo
echo "[5/5] 操作完成"
echo
echo "当前运行内核: ${CURRENT_KERNEL}"
echo "GRUB 默认启动: XanMod"
echo "目标内核: ${XANMOD_KERNEL}"
echo

read -r -p "是否现在重启系统？[y/N]: " REBOOT_CONFIRM

case "$REBOOT_CONFIRM" in
    y|Y)
        echo
        echo "正在重启系统..."
        reboot
        ;;
    *)
        echo
        echo "已取消重启。"
        echo "下次启动将尝试使用 XanMod 默认启动项。"
        ;;
esac
