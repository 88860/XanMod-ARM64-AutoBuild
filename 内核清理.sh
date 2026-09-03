#!/bin/bash
# Kernel Cleanup Utility

set -u
export DEBIAN_FRONTEND=noninteractive

if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 root 运行"
    exit 1
fi

for cmd in uname dpkg dpkg-query apt-get awk sort grep tail; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "缺少命令: $cmd"
        exit 1
    }
done

CURRENT="$(uname -r)"
ARCH="$(dpkg --print-architecture)"

declare -a ALL_KERNELS=()
declare -a DEBIAN_KERNELS=()
declare -a THIRD_KERNELS=()
declare -a CLEANUP=()
declare -a SKIP=()
declare -a DEBIAN_META=()

kernel_type() {
    local r="$1"
    if [[ "$r" =~ \+deb[0-9]+- ]]; then
        echo "debian"
    else
        echo "third"
    fi
}

kernel_base() {
    local r="$1"
    if [[ "$r" =~ ^[0-9]+(\.[0-9]+)* ]]; then
        echo "${BASH_REMATCH[0]}"
    else
        echo "$r"
    fi
}

is_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed
}

kernel_image_pkgs() {
    local r="$1"
    local p
    for p in \
        "linux-image-$r" \
        "linux-image-$r-unsigned" \
        "linux-headers-$r"
    do
        if is_installed "$p"; then
            echo "$p"
        fi
    done
}

is_packaged_kernel() {
    kernel_image_pkgs "$1" | grep -q .
}

find_higher() {
    local current="$1"
    local list="$2"
    local current_base
    local r
    local b
    local higher=""

    current_base="$(kernel_base "$current")"

    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        [[ "$r" == "$current" ]] && continue

        b="$(kernel_base "$r")"
        if [[ "$b" == "$current_base" ]]; then
            continue
        fi
        if [[ "$(printf '%s\n%s\n' "$current_base" "$b" | sort -V | tail -n1)" != "$b" ]]; then
            continue
        fi
        if [[ -z "$higher" || "$(printf '%s\n%s\n' "$(kernel_base "$higher")" "$b" | sort -V | tail -n1)" == "$b" ]]; then
            higher="$r"
        fi
    done <<< "$list"
    echo "$higher"
}

for d in /lib/modules/*; do
    [[ -d "$d" ]] || continue
    r="${d##*/}"
    ALL_KERNELS+=("$r")
    if [[ "$(kernel_type "$r")" == "debian" ]]; then
        DEBIAN_KERNELS+=("$r")
    else
        THIRD_KERNELS+=("$r")
    fi
done

mapfile -t ALL_KERNELS < <(printf '%s\n' "${ALL_KERNELS[@]}" | awk 'NF' | sort -V -u)
mapfile -t DEBIAN_KERNELS < <(printf '%s\n' "${DEBIAN_KERNELS[@]}" | awk 'NF' | sort -V -u)
mapfile -t THIRD_KERNELS < <(printf '%s\n' "${THIRD_KERNELS[@]}" | awk 'NF' | sort -V -u)

case "$ARCH" in
    amd64)
        META_LIST=(
            linux-image-amd64
            linux-image-cloud-amd64
            linux-image-rt-amd64
            linux-headers-amd64
        )
        ;;
    arm64)
        META_LIST=(
            linux-image-arm64
            linux-image-cloud-arm64
            linux-image-rt-arm64
            linux-headers-arm64
        )
        ;;
    *)
        META_LIST=()
        ;;
esac

for p in "${META_LIST[@]}"; do
    if is_installed "$p"; then
        DEBIAN_META+=("$p")
    fi
done

CURRENT_PACKAGED=0
if is_packaged_kernel "$CURRENT"; then
    CURRENT_PACKAGED=1
fi

CURRENT_TYPE="$(kernel_type "$CURRENT")"

if [[ "$CURRENT_TYPE" == "debian" && "$CURRENT_PACKAGED" -eq 1 ]]; then
    HIGHER="$(find_higher "$CURRENT" "$(printf '%s\n' "${DEBIAN_KERNELS[@]}")")"
    if [[ -n "$HIGHER" ]]; then
        echo "====================================================="
        echo "警告：发现比当前运行内核版本更高的 Debian 内核！"
        echo "当前运行内核 : $CURRENT"
        echo "发现更高内核 : $HIGHER"
        echo "====================================================="
        read -r -p "是否仍要以当前内核为准，强制删除更高版本的内核？ [y/N] " FORCE_DEL
        if [[ ! "$FORCE_DEL" =~ ^[Yy]$ ]]; then
            echo "已取消操作。"
            exit 0
        fi
    fi

    for r in "${DEBIAN_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue
        while IFS= read -r p; do
            [[ -n "$p" ]] && CLEANUP+=("$p")
        done < <(kernel_image_pkgs "$r")
    done
else
    CURRENT_MODE=$([[ "$CURRENT_PACKAGED" -eq 0 ]] && echo "自编译" || echo "第三方")
    HIGHER="$(find_higher "$CURRENT" "$(printf '%s\n' "${THIRD_KERNELS[@]}")")"
    
    if [[ -n "$HIGHER" ]]; then
        echo "====================================================="
        echo "警告：发现比当前运行内核版本更高的第三方内核！"
        echo "当前运行内核 : $CURRENT"
        echo "发现更高内核 : $HIGHER"
        echo "====================================================="
        read -r -p "是否仍要以当前内核为准，强制删除更高版本的内核？ [y/N] " FORCE_DEL
        if [[ ! "$FORCE_DEL" =~ ^[Yy]$ ]]; then
            echo "已取消操作。"
            exit 0
        fi
    fi

    for r in "${THIRD_KERNELS[@]}"; do
        [[ "$r" == "$CURRENT" ]] && continue
        if is_packaged_kernel "$r"; then
            while IFS= read -r p; do
                [[ -n "$p" ]] && CLEANUP+=("$p")
            done < <(kernel_image_pkgs "$r")
        else
            SKIP+=("$r")
        fi
    done

    if [[ "${#DEBIAN_KERNELS[@]}" -gt 0 || "${#DEBIAN_META[@]}" -gt 0 ]]; then
        echo "当前内核 : $CURRENT"
        echo "类型     : $CURRENT_MODE"
        echo
        if [[ "${#DEBIAN_KERNELS[@]}" -gt 0 ]]; then
            echo "Debian 内核:"
            printf '  %s\n' "${DEBIAN_KERNELS[@]}"
            echo
        fi
        if [[ "${#DEBIAN_META[@]}" -gt 0 ]]; then
            echo "Debian 元包:"
            printf '  %s\n' "${DEBIAN_META[@]}"
            echo
        fi

        read -r -p "删除残留的 Debian 内核和元包？ [y/N] " ANSWER
        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            for r in "${DEBIAN_KERNELS[@]}"; do
                [[ "$r" == "$CURRENT" ]] && continue
                while IFS= read -r p; do
                    [[ -n "$p" ]] && CLEANUP+=("$p")
                done < <(kernel_image_pkgs "$r")
            done
            CLEANUP+=("${DEBIAN_META[@]}")
        fi
    fi
fi

# ====================================================================
# 深度扫描：检测其他残留的第三方包和元包（确保不遗漏纯元包或孤立头文件）
# ====================================================================
for pkg in $(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^linux-'); do
    # 1. 过滤系统基础包
    if [[ "$pkg" =~ ^linux-(libc-dev|base|compiler|kbuild|doc|perf|source|tools) ]]; then
        continue
    fi
    # 2. 过滤当前正在使用的内核包
    if [[ "$pkg" == *"$CURRENT"* ]]; then
        continue
    fi
    # 3. 依赖链检测：如果它是当前内核的元包，坚决保留
    if dpkg-query -W -f='${Depends} ${Recommends}\n' "$pkg" 2>/dev/null | grep -q "$CURRENT"; then
        continue
    fi
    # 4. 过滤已在清理列表中的包或官方白名单元包
    if [[ " ${CLEANUP[*]} " == *" $pkg "* || " ${SKIP[*]} " == *" $pkg "* || " ${META_LIST[*]} " == *" $pkg "* ]]; then
        continue
    fi
    # 5. 匹配第三方专属特征的包加入清理列表
    if [[ "$pkg" =~ (xanmod|liquorix|bbr|zen|surface|joeyblog|mainline|custom) ]]; then
        CLEANUP+=("$pkg")
    fi
done

declare -A SEEN=()
declare -a UNIQUE_CLEANUP=()

for p in "${CLEANUP[@]}"; do
    [[ -n "${SEEN[$p]+x}" ]] && continue
    SEEN["$p"]=1
    UNIQUE_CLEANUP+=("$p")
done

CLEANUP=("${UNIQUE_CLEANUP[@]}")

if [[ "${#SKIP[@]}" -gt 0 ]]; then
    mapfile -t SKIP < <(printf '%s\n' "${SKIP[@]}" | awk 'NF' | sort -V -u)
    echo
    echo "未被软件包管理，跳过:"
    printf '  %s\n' "${SKIP[@]}"
fi

if [[ "${#CLEANUP[@]}" -eq 0 ]]; then
    echo
    echo "没有需要清理的内核"
    exit 0
fi

for p in "${CLEANUP[@]}"; do
    if [[ "$p" == "linux-image-$CURRENT" || "$p" == "linux-image-$CURRENT-unsigned" || "$p" == "linux-headers-$CURRENT" ]]; then
        echo "严重错误: 试图删除当前运行的内核包，操作中止！"
        exit 1
    fi
done

echo
echo "将删除以下无用内核包:"
printf '  %s\n' "${CLEANUP[@]}"
echo
echo "保留当前内核:"
echo "  $CURRENT"
echo

read -r -p "确认继续删除？ [y/N] " ANSWER
if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "未执行任何操作"
    exit 0
fi

NOW="$(uname -r)"
if [[ "$NOW" != "$CURRENT" ]]; then
    echo "运行内核发生变化，未执行任何操作"
    exit 1
fi

apt-get purge -y --no-install-recommends "${CLEANUP[@]}"

echo -e "\n====================================================="
echo "正在自动更新 GRUB 引导记录..."
update-grub >/dev/null 2>&1 || echo "GRUB 更新失败，请手动检查。"

GRUB_DEFAULT=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | grep '^saved_entry=' | sed 's/^saved_entry=//')
if [ -z "$GRUB_DEFAULT" ]; then
    GRUB_DEFAULT=$(grep '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | awk -F= '{print $2}' | sed "s/['\"]//g")
fi

echo -e "\n===================== 清理总结 ======================"
echo "已成功删除以下内核包:"
printf '   - %s\n' "${CLEANUP[@]}"
echo "-----------------------------------------------------"
echo "当前正在使用的内核 :"
echo "   $CURRENT"
echo "-----------------------------------------------------"
echo "当前 GRUB 默认启动项配置 :"
echo "   ${GRUB_DEFAULT:-0 (默认第一项)}"
echo "====================================================="
