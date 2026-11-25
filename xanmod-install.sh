#!/bin/bash
ARM64_REPO="88860/XanMod-ARM64-AutoBuild"
ARM64_APT_URL="https://88860.github.io/XanMod-ARM64-AutoBuild"
ARM64_KEYRING="/etc/apt/keyrings/xanmod-arm64.gpg"
ARM64_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-arm64.list"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
CHANNELS=("main" "edge" "lts")

CURRENT_KERNEL=""
ARCH=""
RAW_ARCH=""
ARCH_DISPLAY=""
CPU_PSABI=""
CPU_MODEL=""
CPU_HW_NOTE=""
XANMOD_TIER=""
OS_PRETTY_NAME="Unknown Linux"
OS_CODENAME=""
TMP_WORK_DIR=""
ARM64_USE_APT=0

declare -A CH_ONLINE_VER
declare -A CH_TARGET_KERNEL
declare -A CH_PKG_OR_TAG
declare -A CH_INSTALLED_VER
declare -A CH_META_INSTALLED
declare -A CH_UNAVAIL_REASON
declare -A CH_IMG_URL
declare -A CH_HDR_URL
declare -A CH_SUM_URL
declare -A CH_IMG_NAME
declare -A CH_HDR_NAME

init_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[0;31m'
        C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[0;33m'
        C_BLUE=$'\033[0;34m'
        C_MAGENTA=$'\033[0;35m'
        C_CYAN=$'\033[0;36m'
        C_BRED=$'\033[1;31m'
        C_BGREEN=$'\033[1;32m'
        C_BYELLOW=$'\033[1;33m'
        C_BBLUE=$'\033[1;34m'
        C_BMAGENTA=$'\033[1;35m'
        C_BCYAN=$'\033[1;36m'
        C_BWHITE=$'\033[1;37m'
    else
        C_RESET="" C_BOLD="" C_DIM=""
        C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
        C_BRED="" C_BGREEN="" C_BYELLOW="" C_BBLUE="" C_BMAGENTA="" C_BCYAN="" C_BWHITE=""
    fi
}

cleanup_tmp() {
    if [ -n "$TMP_WORK_DIR" ] && [ -d "$TMP_WORK_DIR" ]; then
        rm -rf "$TMP_WORK_DIR"
    fi
}

ensure_tmp_dir() {
    if [ -z "$TMP_WORK_DIR" ] || [ ! -d "$TMP_WORK_DIR" ]; then
        TMP_WORK_DIR=$(mktemp -d)
        chmod 0755 "$TMP_WORK_DIR"
    fi
}

hr() {
    echo -e "${C_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
}

hr_thin() {
    echo -e "${C_DIM}──────────────────────────────────────────────────────────────────────${C_RESET}"
}

info() {
    echo -e "${C_BCYAN}[信息]${C_RESET} $*"
}

ok() {
    echo -e "${C_BGREEN}[成功]${C_RESET} $*"
}

warn() {
    echo -e "${C_BYELLOW}[警告]${C_RESET} $*"
}

err() {
    echo -e "${C_BRED}[错误]${C_RESET} $*" >&2
}

die() {
    err "$1"
    exit 1
}

pause_continue() {
    local msg="${1:-按回车键继续...}"
    echo ""
    read -r -p "  ${C_DIM}${msg}${C_RESET} " _
}

prompt_enter_reboot() {
    local reason="$1"
    echo ""
    hr
    ok "$reason"
    echo -e "  ${C_BYELLOW}提示: 按回车键立即重启系统使更改生效${C_RESET} ${C_DIM}(或按 Ctrl+C 取消并稍后手动重启)${C_RESET}"
    read -r -p "  > " _
    cleanup_tmp
    info "正在重启系统..."
    reboot || /sbin/reboot || systemctl reboot || die "执行重启失败，请手动执行 reboot"
}

print_banner() {
    echo ""
    hr
    echo -e "  ${C_BCYAN}XanMod 内核管理脚本${C_RESET}  ${C_DIM}(x86_64 & ARM64)${C_RESET}"
    hr
}

print_system_summary() {
    local kernel_color="$C_BYELLOW"
    if [[ "$CURRENT_KERNEL" == *xanmod* ]]; then
        kernel_color="$C_BGREEN"
    fi

    local os_line="${OS_PRETTY_NAME}"
    if [ -n "$OS_CODENAME" ] && [[ "$OS_PRETTY_NAME" != *"(${OS_CODENAME})"* ]]; then
        os_line="${OS_PRETTY_NAME} (${OS_CODENAME})"
    fi

    echo -e "  ${C_DIM}当前运行内核 :${C_RESET} ${kernel_color}${CURRENT_KERNEL}${C_RESET}"
    echo -e "  ${C_DIM}机器系统架构 :${C_RESET} ${C_BCYAN}${ARCH_DISPLAY}${C_RESET}   ${C_DIM}指令集 / 平台 :${C_RESET} ${C_BMAGENTA}${CPU_PSABI}${C_RESET}"
    echo -e "  ${C_DIM}操作系统环境 :${C_RESET} ${C_BWHITE}${os_line}${C_RESET}"
    hr
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    fi
}

cpu_has_all_flags() {
    local flags_str="$1"
    shift
    local f
    for f in "$@"; do
        case " $flags_str " in
            *" $f "*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

probe_cpu_isa() {
    local verbose="${1:-0}"

    if [ "$verbose" -eq 1 ]; then
        info "正在检测 CPU 指令集架构..."
    fi

    CPU_MODEL=""
    CPU_HW_NOTE=""

    if [ "$ARCH" = "amd64" ]; then
        ARCH_DISPLAY="x86_64 (amd64)"
        local cpu_flags="" ld_so="" ld_help=""
        if [ -r /proc/cpuinfo ]; then
            CPU_MODEL=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 | tr -s ' ')
            cpu_flags=$(sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 | tr '\n' ' ')
        fi

        local cand_ld
        for cand_ld in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
            if [ -x "$cand_ld" ]; then
                ld_so="$cand_ld"
                break
            fi
        done
        if [ -n "$ld_so" ]; then
            ld_help=$(LC_ALL=C "$ld_so" --help 2>/dev/null || true)
        fi

        local flag_v2=0 flag_v3=0 flag_v4=0
        if [ -n "$cpu_flags" ]; then
            if cpu_has_all_flags "$cpu_flags" cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2; then
                flag_v2=1
            fi
            if [ "$flag_v2" -eq 1 ] && cpu_has_all_flags "$cpu_flags" avx avx2 bmi1 bmi2 f16c fma movbe; then
                if cpu_has_all_flags "$cpu_flags" abm || cpu_has_all_flags "$cpu_flags" lzcnt; then
                    flag_v3=1
                fi
            fi
            if [ "$flag_v3" -eq 1 ] && cpu_has_all_flags "$cpu_flags" avx512f avx512bw avx512cd avx512dq avx512vl; then
                flag_v4=1
            fi
        fi

        local ld_has_hwcaps=0 ld_v2=0 ld_v3=0 ld_v4=0
        if grep -qE 'x86-64-v[2-4] \(supported, searched\)' <<< "$ld_help"; then
            ld_has_hwcaps=1
            grep -q 'x86-64-v2 (supported, searched)' <<< "$ld_help" && ld_v2=1
            grep -q 'x86-64-v3 (supported, searched)' <<< "$ld_help" && ld_v3=1
            grep -q 'x86-64-v4 (supported, searched)' <<< "$ld_help" && ld_v4=1
        fi

        local detected_level="v1"
        if [ "$ld_has_hwcaps" -eq 1 ]; then
            if [ "$ld_v3" -eq 1 ] && { [ -z "$cpu_flags" ] || [ "$flag_v3" -eq 1 ]; }; then
                detected_level="v3"
                if [ "$ld_v4" -eq 1 ] && { [ -z "$cpu_flags" ] || [ "$flag_v4" -eq 1 ]; }; then
                    CPU_HW_NOTE="硬件支持 x86-64-v4 (AVX-512)；XanMod 官方最高档位为 x64v3"
                fi
            elif [ "$ld_v2" -eq 1 ] && { [ -z "$cpu_flags" ] || [ "$flag_v2" -eq 1 ]; }; then
                detected_level="v2"
            else
                detected_level="v1"
            fi
        elif [ -n "$cpu_flags" ]; then
            if [ "$flag_v4" -eq 1 ]; then
                detected_level="v3"
                CPU_HW_NOTE="硬件支持 x86-64-v4 (AVX-512)；XanMod 官方最高档位为 x64v3"
            elif [ "$flag_v3" -eq 1 ]; then
                detected_level="v3"
            elif [ "$flag_v2" -eq 1 ]; then
                detected_level="v2"
            else
                detected_level="v1"
            fi
        fi

        case "$detected_level" in
            v3)
                CPU_PSABI="x86-64-v3"
                XANMOD_TIER="x64v3"
                ;;
            v2)
                CPU_PSABI="x86-64-v2"
                XANMOD_TIER="x64v2"
                ;;
            *)
                CPU_PSABI="x86-64-v1"
                XANMOD_TIER="x64v1"
                CPU_HW_NOTE="仅 LTS 通道提供 x64v1 (MAIN / EDGE 需 >= x86-64-v2)"
                ;;
        esac

        if [ "$verbose" -eq 1 ]; then
            [ -n "$CPU_MODEL" ] && echo -e "  ${C_DIM}处理器型号   :${C_RESET} ${C_BWHITE}${CPU_MODEL}${C_RESET}"
            echo -e "  ${C_DIM}检测方式     :${C_RESET} $( [ "$ld_has_hwcaps" -eq 1 ] && echo "glibc ld-linux psABI + /proc/cpuinfo 标志校验" || echo "/proc/cpuinfo ISA 标志校验" )"
            echo -e "  ${C_DIM}适配指令集   :${C_RESET} ${C_BMAGENTA}${CPU_PSABI}${C_RESET}  ${C_DIM}(对应官方包等级: ${XANMOD_TIER})${C_RESET}"
            [ -n "$CPU_HW_NOTE" ] && echo -e "  ${C_DIM}补充说明     :${C_RESET} ${C_BCYAN}${CPU_HW_NOTE}${C_RESET}"
        fi
    elif [ "$ARCH" = "arm64" ]; then
        ARCH_DISPLAY="ARM64 (aarch64)"
        CPU_PSABI="ARM64 (${ARM64_REPO})"
        XANMOD_TIER="arm64"
        local arm_feats=""
        if [ -r /proc/cpuinfo ]; then
            arm_feats=$(sed -n 's/^Features[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n1 | tr -s ' ')
        fi
        if [ "$verbose" -eq 1 ]; then
            echo -e "  ${C_DIM}机器架构     :${C_RESET} ${C_BCYAN}ARM64 / aarch64${C_RESET}"
            [ -n "$arm_feats" ] && echo -e "  ${C_DIM}指令集特性   :${C_RESET} ${C_DIM}${arm_feats}${C_RESET}"
            echo -e "  ${C_DIM}适配目标     :${C_RESET} ${C_BMAGENTA}ARM64${C_RESET}"
        fi
    else
        ARCH_DISPLAY="不支持的架构 (${ARCH} / ${RAW_ARCH})"
        CPU_PSABI="未知"
        XANMOD_TIER=""
    fi
}

detect_system_info() {
    CURRENT_KERNEL=$(uname -r)
    RAW_ARCH=$(uname -m)
    ARCH=$(dpkg --print-architecture 2>/dev/null || true)

    if [ -z "$ARCH" ]; then
        case "$RAW_ARCH" in
            x86_64|amd64)   ARCH="amd64" ;;
            aarch64|arm64)  ARCH="arm64" ;;
            *)              ARCH="$RAW_ARCH" ;;
        esac
    fi

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        OS_PRETTY_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    fi
    if [ -z "$OS_CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
        OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
    fi

    probe_cpu_isa 0
}

check_runtime_tools() {
    local cmd
    for cmd in awk gzip dpkg dpkg-query dpkg-deb apt-get sha256sum base64; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "系统缺少必要基础命令: $cmd"
            return 1
        fi
    done

    if command -v curl >/dev/null 2>&1 || \
       command -v wget >/dev/null 2>&1 || \
       command -v python3 >/dev/null 2>&1 || \
       [ -x /usr/lib/apt/apt-helper ]; then
        return 0
    fi

    err "未检测到可用 HTTP 下载工具 (curl / wget / python3 / apt-helper)"
    return 1
}

http_get() {
    local url="$1"
    local dest="$2"
    local max_time="${3:-60}"
    local quiet="${4:-1}"

    rm -f "$dest"

    if command -v curl >/dev/null 2>&1; then
        if [ "$quiet" -eq 1 ]; then
            curl -fsSL --connect-timeout 15 --max-time "$max_time" -o "$dest" "$url" 2>/dev/null
        else
            curl -fSL --connect-timeout 15 --max-time "$max_time" -o "$dest" "$url"
        fi
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        if [ "$quiet" -eq 1 ]; then
            wget -q --timeout=30 -O "$dest" "$url" 2>/dev/null
        else
            wget --show-progress --timeout=30 -O "$dest" "$url" || wget -O "$dest" "$url"
        fi
        return $?
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$url" "$dest" "$max_time" << 'PY_EOF'
import sys, urllib.request, shutil
url, dest, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
req = urllib.request.Request(url, headers={"User-Agent": "xanmod-install"})
with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f:
    shutil.copyfileobj(r, f)
PY_EOF
        return $?
    fi

    if [ -x /usr/lib/apt/apt-helper ]; then
        if /usr/lib/apt/apt-helper -q download-file "$url" "$dest" >/dev/null 2>&1; then
            return 0
        fi
        if [ "$quiet" -eq 1 ]; then
            /usr/lib/apt/apt-helper -q -o APT::Sandbox::User=root download-file "$url" "$dest" >/dev/null 2>&1
        else
            /usr/lib/apt/apt-helper -o APT::Sandbox::User=root download-file "$url" "$dest"
        fi
        return $?
    fi

    return 1
}

dearmor_pgp_key() {
    local asc_in="$1"
    local gpg_out="$2"

    [ -s "$asc_in" ] || return 1

    if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$asc_in" 2>/dev/null; then
        cp -f "$asc_in" "$gpg_out"
        return $?
    fi

    if command -v gpg >/dev/null 2>&1; then
        gpg --dearmor --yes -o "$gpg_out" "$asc_in"
        return $?
    fi

    awk '
        BEGIN { body = 0 }
        { sub(/\r$/, "") }
        /^$/ { if (!body) { body = 1; next } }
        /^-----END / { exit }
        /^=/ { if (body) exit }
        body { print }
    ' "$asc_in" | base64 -d > "$gpg_out" 2>/dev/null

    [ -s "$gpg_out" ]
}

parse_arm64_release_json() {
    local rel_json="$1"
    local ch="$2"

    if command -v jq >/dev/null 2>&1; then
        if ! jq -e 'type == "array"' "$rel_json" >/dev/null 2>&1; then
            return 2
        fi
        jq -r --arg ch "$ch" '
            [
                .[]
                | select(.draft == false and .prerelease == false)
                | select(
                    ((.tag_name // "") | ascii_downcase | endswith("-" + $ch))
                    or
                    ((.name // "") | ascii_downcase | contains("arm64 " + $ch))
                )
            ][0] as $r
            | if $r == null then
                ""
              else
                (
                    ([$r.assets[]? | select(.name | test("^linux-image-.*arm64\\.deb$"))][0] // {}) as $img
                    | ([$r.assets[]? | select(.name | test("^linux-headers-.*arm64\\.deb$"))][0] // {}) as $hdr
                    | ([$r.assets[]? | select(.name == "SHA256SUMS")][0] // {}) as $sum
                    | [
                        ($r.tag_name // ""),
                        ($img.name // ""),
                        ($img.browser_download_url // ""),
                        ($hdr.name // ""),
                        ($hdr.browser_download_url // ""),
                        ($sum.browser_download_url // "")
                    ] | @tsv
                )
              end
        ' "$rel_json"
        return $?
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$rel_json" "$ch" << 'PY_EOF'
import json, re, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, list):
    sys.exit(2)
ch = sys.argv[2].lower()
for r in data:
    if not isinstance(r, dict) or r.get("draft") or r.get("prerelease"):
        continue
    tag = r.get("tag_name") or ""
    name = r.get("name") or ""
    if tag.lower().endswith("-" + ch) or ("arm64 " + ch) in name.lower():
        assets = r.get("assets") or []
        img = next((a for a in assets if re.match(r"^linux-image-.*arm64\.deb$", a.get("name") or "")), {})
        hdr = next((a for a in assets if re.match(r"^linux-headers-.*arm64\.deb$", a.get("name") or "")), {})
        sums = next((a for a in assets if a.get("name") == "SHA256SUMS"), {})
        print("\t".join([
            tag,
            img.get("name") or "",
            img.get("browser_download_url") or "",
            hdr.get("name") or "",
            hdr.get("browser_download_url") or "",
            sums.get("browser_download_url") or "",
        ]))
        break
PY_EOF
        return $?
    fi

    awk -v ch="$ch" '
        function chomp_ws() {
            while (pos <= len) {
                c = substr(buf, pos, 1)
                if (c == " " || c == "\t" || c == "\r" || c == "\n") pos++
                else break
            }
        }
        function read_str(   out, c, esc) {
            pos++
            out = ""
            while (pos <= len) {
                c = substr(buf, pos, 1)
                if (c == "\"") { pos++; return out }
                if (c == "\\") {
                    pos++
                    esc = substr(buf, pos, 1)
                    if (esc == "n") out = out "\n"
                    else if (esc == "r") out = out "\r"
                    else if (esc == "t") out = out "\t"
                    else if (esc == "u") { if (pos + 4 <= len) pos += 4; else pos = len }
                    else out = out esc
                    pos++
                } else {
                    out = out c
                    pos++
                }
            }
            return out
        }
        function read_lit(   start, c) {
            start = pos
            while (pos <= len) {
                c = substr(buf, pos, 1)
                if (c ~ /[ \t\r\n,}\]]/) break
                pos++
            }
            return substr(buf, start, pos - start)
        }
        function next_tok(   c) {
            chomp_ws()
            if (pos > len) { tok_t = "EOF"; tok_v = ""; return 0 }
            c = substr(buf, pos, 1)
            if (c == "\"") { tok_t = "STR"; tok_v = read_str(); return 1 }
            if (c == "{" || c == "}" || c == "[" || c == "]" || c == ":" || c == ",") {
                tok_t = c; tok_v = c; pos++; return 1
            }
            tok_t = "LIT"; tok_v = read_lit(); return 1
        }
        function reset_rel() {
            r_tag = ""; r_name = ""; r_draft = ""; r_pre = ""
            a_img_n = ""; a_img_u = ""; a_hdr_n = ""; a_hdr_u = ""; a_sum_u = ""
        }
        function emit_if_match(   lt, ln) {
            if (r_draft == "true" || r_pre == "true") return 0
            lt = tolower(r_tag); ln = tolower(r_name)
            if ((length(lt) > length(ch) && substr(lt, length(lt) - length(ch)) == ("-" ch)) || index(ln, "arm64 " ch) > 0) {
                print r_tag "\t" a_img_n "\t" a_img_u "\t" a_hdr_n "\t" a_hdr_u "\t" a_sum_u
                return 1
            }
            return 0
        }
        BEGIN { buf = "" }
        { buf = buf $0 "\n" }
        END {
            len = length(buf); pos = 1
            next_tok()
            if (tok_t != "[") exit 2
            od = 0; arr_skip = 0; in_assets = 0
            while (next_tok()) {
                if (tok_t == "EOF") break
                if (tok_t == "{") {
                    od++
                    if (od == 1) { reset_rel(); expect_key[1] = 1; key_name[1] = ""; in_assets = 0 }
                    else if (od == 2 && in_assets) { cur_an = ""; cur_au = ""; expect_key[2] = 1; key_name[2] = "" }
                    else if (od > 0) { expect_key[od] = 1; key_name[od] = "" }
                    continue
                }
                if (tok_t == "}") {
                    if (od == 2 && in_assets) {
                        if (cur_an ~ /^linux-image-.*arm64\.deb$/ && a_img_n == "") { a_img_n = cur_an; a_img_u = cur_au }
                        else if (cur_an ~ /^linux-headers-.*arm64\.deb$/ && a_hdr_n == "") { a_hdr_n = cur_an; a_hdr_u = cur_au }
                        else if (cur_an == "SHA256SUMS" && a_sum_u == "") { a_sum_u = cur_au }
                    }
                    if (od == 1) {
                        if (emit_if_match()) exit 0
                    }
                    od--
                    if (od < 0) od = 0
                    continue
                }
                if (tok_t == "[") {
                    if (od == 1 && key_name[1] == "assets" && !expect_key[1]) in_assets = 1
                    else if (od > 0) arr_skip++
                    continue
                }
                if (tok_t == "]") {
                    if (od == 1 && in_assets && arr_skip == 0) { in_assets = 0; key_name[1] = "" }
                    else if (arr_skip > 0) arr_skip--
                    else if (od == 0) break
                    continue
                }
                if (tok_t == ":") continue
                if (tok_t == ",") {
                    if (od > 0) { expect_key[od] = 1; key_name[od] = "" }
                    continue
                }
                if (od > 0 && expect_key[od] && tok_t == "STR" && arr_skip == 0) {
                    key_name[od] = tok_v
                    expect_key[od] = 0
                } else if (od == 1 && !expect_key[1] && !in_assets && arr_skip == 0) {
                    if (key_name[1] == "tag_name") r_tag = tok_v
                    else if (key_name[1] == "name") r_name = tok_v
                    else if (key_name[1] == "draft") r_draft = tok_v
                    else if (key_name[1] == "prerelease") r_pre = tok_v
                    key_name[1] = ""
                } else if (od == 2 && !expect_key[2] && in_assets && arr_skip == 0) {
                    if (key_name[2] == "name") cur_an = tok_v
                    else if (key_name[2] == "browser_download_url") cur_au = tok_v
                    key_name[2] = ""
                }
            }
        }
    ' "$rel_json"
}

get_latest_xanmod_modules() {
    find /lib/modules \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
        grep -i 'xanmod' |
        sort -V |
        tail -n1
}

channel_label() {
    case "$1" in
        main) echo "MAIN (主线稳定版)" ;;
        edge) echo "EDGE (前沿尝鲜版)" ;;
        lts)  echo "LTS  (长期支持版)" ;;
        *)    echo "$1" ;;
    esac
}

channel_color() {
    case "$1" in
        main) echo "$C_BCYAN" ;;
        edge) echo "$C_BMAGENTA" ;;
        lts)  echo "$C_BBLUE" ;;
        *)    echo "$C_BWHITE" ;;
    esac
}

extract_grub_menu_id() {
    local target_kernel="$1"
    local grub_cfg="$2"

    awk -v k="vmlinuz-${target_kernel}" '
        /^[[:space:]]*submenu[[:space:]]/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /id_option$/ || $i == "--id") {
                    id = $(i + 1)
                    gsub(/'\''/, "", id)
                    sub_id = id
                }
            }
        }
        /^[[:space:]]*menuentry[[:space:]]/ {
            m_id = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /id_option$/ || $i == "--id") {
                    id = $(i + 1)
                    gsub(/'\''/, "", id)
                    m_id = id
                }
            }
            if ($0 ~ /recovery/) {
                m_id = ""
            }
        }
        /^\}[[:space:]]*$/ {
            sub_id = ""
        }
        m_id != "" {
            pos = index($0, k)
            if (pos > 0) {
                nextch = substr($0, pos + length(k), 1)
                if (nextch == "" || nextch ~ /[[:space:]'\''"]/) {
                    if (sub_id != "") {
                        print sub_id ">" m_id
                    } else {
                        print m_id
                    }
                    exit
                }
            }
        }
    ' "$grub_cfg"
}

configure_grub_for_kernel() {
    local target_kernel="$1"
    local grub_cfg="/boot/grub/grub.cfg"
    local grub_default_file="/etc/default/grub"

    if ! command -v update-grub >/dev/null 2>&1 || ! command -v grub-set-default >/dev/null 2>&1 || ! command -v grub-editenv >/dev/null 2>&1 || [ ! -d /boot/grub ]; then
        warn "未检测到可用 GRUB 工具链或 /boot/grub 目录，已跳过 GRUB 配置"
        warn "若系统使用 systemd-boot、extlinux 或其它引导器，请手动确认默认内核指向: ${target_kernel}"
        return 0
    fi

    echo ""
    info "正在更新 GRUB 配置并设置默认启动内核: ${C_BGREEN}${target_kernel}${C_RESET} ..."
    if ! update-grub; then
        err "update-grub 执行失败"
        return 1
    fi

    if [ ! -f "$grub_cfg" ]; then
        err "未找到 GRUB 配置文件 ($grub_cfg)"
        return 1
    fi

    local grub_id=""
    grub_id=$(extract_grub_menu_id "$target_kernel" "$grub_cfg")
    if [ -z "$grub_id" ]; then
        err "未能从 $grub_cfg 提取到内核 ${target_kernel} 的非 recovery 启动项 ID"
        return 1
    fi

    if [ ! -f "$grub_default_file" ]; then
        err "未找到 $grub_default_file"
        return 1
    fi

    if grep -q '^GRUB_DEFAULT=' "$grub_default_file"; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$grub_default_file"
    else
        printf '%s\n' 'GRUB_DEFAULT=saved' >> "$grub_default_file"
    fi

    if grep -q '^GRUB_SAVEDEFAULT=' "$grub_default_file"; then
        sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=false/' "$grub_default_file"
    else
        printf '%s\n' 'GRUB_SAVEDEFAULT=false' >> "$grub_default_file"
    fi

    if [ -d /etc/default/grub.d ] && grep -Eq '^[[:space:]]*(GRUB_DEFAULT|GRUB_SAVEDEFAULT)=' /etc/default/grub.d/*.cfg 2>/dev/null; then
        printf 'GRUB_DEFAULT=saved\nGRUB_SAVEDEFAULT=false\n' > /etc/default/grub.d/99-xanmod-default.cfg
    fi

    if ! grub-set-default "$grub_id"; then
        err "grub-set-default 设置失败"
        return 1
    fi

    local saved_entry=""
    saved_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
    if [ "$saved_entry" != "$grub_id" ]; then
        err "GRUB 默认启动项校验失败 (期望: $grub_id，实际: ${saved_entry:-空})"
        return 1
    fi

    if ! update-grub >/dev/null 2>&1; then
        warn "最终 update-grub 返回非零状态，请手动复查"
    fi

    echo ""
    hr_thin
    echo -e "  ${C_BGREEN}GRUB 配置完成${C_RESET}"
    echo -e "  ${C_DIM}默认启动内核 :${C_RESET} ${C_BGREEN}${target_kernel}${C_RESET}"
    echo -e "  ${C_DIM}GRUB 启动项ID:${C_RESET} ${C_BCYAN}${grub_id}${C_RESET}"
    hr_thin
    return 0
}

reset_channel_cache() {
    local ch
    ARM64_USE_APT=0
    for ch in "${CHANNELS[@]}"; do
        CH_ONLINE_VER[$ch]=""
        CH_TARGET_KERNEL[$ch]=""
        CH_PKG_OR_TAG[$ch]=""
        CH_INSTALLED_VER[$ch]=""
        CH_META_INSTALLED[$ch]=""
        CH_UNAVAIL_REASON[$ch]=""
        CH_IMG_URL[$ch]=""
        CH_HDR_URL[$ch]=""
        CH_SUM_URL[$ch]=""
        CH_IMG_NAME[$ch]=""
        CH_HDR_NAME[$ch]=""
    done
}

extract_image_krel_from_depends() {
    local deps="$1"
    sed -n 's/.*linux-image-\([0-9][^ ,|()]*\).*/\1/p' <<< "$deps" | head -n1
}

lookup_apt_metapkg() {
    local repo_txt="$1"
    local pkg="$2"
    awk -v pkg="$pkg" '
        BEGIN { RS=""; FS="\n" }
        {
            p=""; v=""; d=""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /)  p = substr($i, 10)
                if ($i ~ /^Version: /)  v = substr($i, 10)
                if ($i ~ /^Depends: /)  d = substr($i, 10)
            }
            if (p == pkg && v != "") {
                print v "\t" d
            }
        }
    ' "$repo_txt" | sort -V | tail -n1
}

record_apt_metapkg_state() {
    local ch="$1"
    local pkg="$2"
    local repo_txt="$3"
    local missing_msg="$4"
    local installed_imgs="${5:-}"

    CH_PKG_OR_TAG[$ch]="$pkg"

    local parsed_line=""
    parsed_line=$(lookup_apt_metapkg "$repo_txt" "$pkg")
    if [ -n "$parsed_line" ]; then
        CH_ONLINE_VER[$ch]="${parsed_line%%$'\t'*}"
        local deps="${parsed_line#*$'\t'}"
        CH_TARGET_KERNEL[$ch]=$(extract_image_krel_from_depends "$deps")
    else
        CH_UNAVAIL_REASON[$ch]="$missing_msg"
    fi

    local meta_info=""
    meta_info=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Version}\n' "$pkg" 2>/dev/null || true)
    if [[ "$meta_info" == ii* || "$meta_info" == hi* ]]; then
        CH_META_INSTALLED[$ch]="${meta_info#*$'\t'}"
        CH_INSTALLED_VER[$ch]="${CH_META_INSTALLED[$ch]}"
    elif [ -n "$installed_imgs" ] && [ -n "${CH_TARGET_KERNEL[$ch]}" ]; then
        local target_k="${CH_TARGET_KERNEL[$ch]}"
        local online_mm=""
        if [[ "$target_k" =~ ^([0-9]+\.[0-9]+)\. ]]; then
            online_mm="${BASH_REMATCH[1]}"
        fi
        if grep -Fxq "$target_k" <<< "$installed_imgs" || [ -d "/lib/modules/${target_k}" ]; then
            CH_INSTALLED_VER[$ch]="$target_k"
        elif [ -n "$online_mm" ]; then
            local same_series=""
            same_series=$(grep -E "^${online_mm}\." <<< "$installed_imgs" | sort -V | tail -n1 || true)
            [ -n "$same_series" ] && CH_INSTALLED_VER[$ch]="$same_series"
        fi
    fi
}

fetch_amd64_channels() {
    if [ -z "$OS_CODENAME" ]; then
        err "无法识别当前系统发行版代号 (VERSION_CODENAME)，无法匹配 deb.xanmod.org 仓库"
        return 1
    fi

    ensure_tmp_dir
    local repo_gz="${TMP_WORK_DIR}/amd64-Packages.gz"
    local repo_txt="${TMP_WORK_DIR}/amd64-Packages"
    local repo_url="http://deb.xanmod.org/dists/${OS_CODENAME}/main/binary-amd64/Packages.gz"

    info "正在从 XanMod 官方源检测 ${C_BCYAN}${OS_CODENAME}${C_RESET} (${C_BMAGENTA}${CPU_PSABI}${C_RESET}) 最新可用版本..."
    if ! http_get "$repo_url" "$repo_gz" 30 1; then
        err "无法获取 XanMod 官方仓库索引: $repo_url"
        err "提示: 请检查网络连接，或确认官方源是否支持当前发行版代号 '${OS_CODENAME}'"
        return 1
    fi

    if ! gzip -dc "$repo_gz" > "$repo_txt" 2>/dev/null; then
        err "解压 XanMod 仓库 Packages.gz 失败"
        return 1
    fi

    local ch pkg
    for ch in "${CHANNELS[@]}"; do
        case "$ch" in
            main)
                if [ "$XANMOD_TIER" = "x64v1" ]; then
                    CH_UNAVAIL_REASON[$ch]="官方 MAIN 通道不提供 x86-64-v1"
                    continue
                fi
                pkg="linux-xanmod-${XANMOD_TIER}"
                ;;
            edge)
                if [ "$XANMOD_TIER" = "x64v1" ]; then
                    CH_UNAVAIL_REASON[$ch]="官方 EDGE 通道不提供 x86-64-v1"
                    continue
                fi
                pkg="linux-xanmod-edge-${XANMOD_TIER}"
                ;;
            lts)
                pkg="linux-xanmod-lts-${XANMOD_TIER}"
                ;;
        esac
        record_apt_metapkg_state "$ch" "$pkg" "$repo_txt" "源 '${OS_CODENAME}' 暂未收录 ${pkg}"
    done

    return 0
}

arm64_metapkg_name() {
    case "$1" in
        main) printf 'linux-xanmod-arm64' ;;
        edge) printf 'linux-xanmod-edge-arm64' ;;
        lts)  printf 'linux-xanmod-lts-arm64' ;;
    esac
}

fetch_arm64_apt_channels() {
    ensure_tmp_dir
    local repo_gz="${TMP_WORK_DIR}/arm64-Packages.gz"
    local repo_txt="${TMP_WORK_DIR}/arm64-Packages"
    local repo_url="${ARM64_APT_URL}/dists/stable/main/binary-arm64/Packages.gz"

    info "正在从 GitHub Pages APT 源 (${C_BCYAN}${ARM64_APT_URL}${C_RESET}) 检测 ARM64 最新可用版本..."
    if ! http_get "$repo_url" "$repo_gz" 20 1; then
        return 1
    fi
    if ! gzip -dc "$repo_gz" > "$repo_txt" 2>/dev/null || [ ! -s "$repo_txt" ]; then
        return 1
    fi

    local installed_imgs=""
    installed_imgs=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*xanmod*' 2>/dev/null |
        awk '$1 ~ /^(ii|hi)$/ { sub(/^linux-image-/, "", $2); print $2 }' || true)

    local ch pkg found_any=0
    for ch in "${CHANNELS[@]}"; do
        pkg=$(arm64_metapkg_name "$ch")
        record_apt_metapkg_state "$ch" "$pkg" "$repo_txt" "APT 源暂未收录 ${pkg}" "$installed_imgs"
        if [ -n "${CH_ONLINE_VER[$ch]}" ]; then
            found_any=1
        fi
    done

    if [ "$found_any" -eq 0 ]; then
        return 1
    fi
    ARM64_USE_APT=1
    return 0
}

fetch_arm64_channels() {
    if fetch_arm64_apt_channels; then
        return 0
    fi
    reset_channel_cache
    warn "GitHub Pages APT 源暂不可用或尚未部署，回退至 GitHub Releases 检测..."

    ensure_tmp_dir
    local api_url="https://api.github.com/repos/${ARM64_REPO}/releases?per_page=100"
    local rel_json="${TMP_WORK_DIR}/arm64-releases.json"

    info "正在从 GitHub Releases (${C_BCYAN}${ARM64_REPO}${C_RESET}) 检测 ARM64 最新可用版本..."
    if ! http_get "$api_url" "$rel_json" 30 1; then
        err "无法访问 GitHub Releases API ($api_url)"
        err "提示: 请检查网络连接、系统 CA 证书 (/etc/ssl/certs/ca-certificates.crt)，或确认是否触发 API 速率限制"
        return 1
    fi

    local installed_imgs=""
    installed_imgs=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 'linux-image-*xanmod*' 2>/dev/null |
        awk '$1 ~ /^(ii|hi)$/ { sub(/^linux-image-/, "", $2); print $2 }' || true)

    local ch
    for ch in "${CHANNELS[@]}"; do
        local ch_line="" parse_rc=0
        ch_line=$(parse_arm64_release_json "$rel_json" "$ch") || parse_rc=$?
        if [ "$parse_rc" -eq 2 ]; then
            err "GitHub Releases 返回数据格式异常 (非数组)"
            return 1
        elif [ "$parse_rc" -ne 0 ]; then
            err "解析 GitHub Releases JSON 失败"
            return 1
        fi

        if [ -z "$ch_line" ]; then
            CH_UNAVAIL_REASON[$ch]="GitHub 暂未发布 ARM64 ${ch^^} Release"
            continue
        fi

        local tag="" img_name="" img_url="" hdr_name="" hdr_url="" sum_url=""
        IFS=$'\t' read -r tag img_name img_url hdr_name hdr_url sum_url <<< "$ch_line"

        local online_ver="$tag"
        if [[ "${online_ver,,}" == *"-${ch}" ]]; then
            online_ver="${online_ver:0:${#online_ver}-${#ch}-1}"
        fi

        CH_PKG_OR_TAG[$ch]="$tag"
        CH_ONLINE_VER[$ch]="$online_ver"
        CH_IMG_NAME[$ch]="$img_name"
        CH_IMG_URL[$ch]="$img_url"
        CH_HDR_NAME[$ch]="$hdr_name"
        CH_HDR_URL[$ch]="$hdr_url"
        CH_SUM_URL[$ch]="$sum_url"

        if [ -n "$img_name" ]; then
            local krel="${img_name#linux-image-}"
            krel="${krel%%_*}"
            CH_TARGET_KERNEL[$ch]="$krel"
        else
            CH_TARGET_KERNEL[$ch]="$online_ver"
        fi

        if [ -z "$img_url" ] || [ -z "$hdr_url" ]; then
            CH_UNAVAIL_REASON[$ch]="Release (${tag}) 缺少完整的 image/headers deb 资产"
            CH_ONLINE_VER[$ch]=""
            continue
        fi

        local target_k="${CH_TARGET_KERNEL[$ch]}"
        local online_mm=""
        if [[ "$target_k" =~ ^([0-9]+\.[0-9]+)\. ]]; then
            online_mm="${BASH_REMATCH[1]}"
        fi

        if grep -Fxq "$target_k" <<< "$installed_imgs" || [ -d "/lib/modules/${target_k}" ]; then
            CH_INSTALLED_VER[$ch]="$target_k"
        elif [ -n "$online_mm" ]; then
            local same_series=""
            same_series=$(grep -E "^${online_mm}\." <<< "$installed_imgs" | sort -V | tail -n1 || true)
            if [ -n "$same_series" ]; then
                CH_INSTALLED_VER[$ch]="$same_series"
            fi
        fi
    done

    return 0
}

print_installed_xanmod_summary() {
    local found_any=0
    echo -e "  ${C_DIM}本机已安装 XanMod 内核:${C_RESET}"
    local line status pkg ver
    while IFS=$'\t' read -r status pkg ver; do
        [ -n "$pkg" ] || continue
        if [[ "$status" == ii* || "$status" == hi* ]]; then
            found_any=1
            local krel="${pkg#linux-image-}"
            local tag_run=""
            if [ "$krel" = "$CURRENT_KERNEL" ]; then
                tag_run=" ${C_BGREEN}[正在运行]${C_RESET}"
            fi
            echo -e "    ${C_GREEN}•${C_RESET} ${C_BWHITE}${pkg}${C_RESET}  ${C_DIM}版本:${C_RESET} ${C_CYAN}${ver}${C_RESET}${tag_run}"
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'linux-image-*xanmod*' 2>/dev/null || true)

    if [ "$found_any" -eq 0 ]; then
        echo -e "    ${C_DIM}(未检测到已安装的 XanMod 内核包)${C_RESET}"
    fi
}

setup_apt_repo() {
    local label="$1"
    local key_url="$2"
    local keyring="$3"
    local source_line="$4"
    local source_file="$5"

    ensure_tmp_dir
    local key_tmp="${TMP_WORK_DIR}/apt-archive.key"

    info "正在配置 ${label} APT 密钥与软件源..."
    if ! http_get "$key_url" "$key_tmp" 30 1; then
        err "下载 ${label} GPG 密钥失败: $key_url"
        return 1
    fi

    if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$key_tmp" 2>/dev/null; then
        err "获取的 GPG 公钥格式无效: $key_url"
        return 1
    fi

    install -d -m 0755 /etc/apt/keyrings
    if ! dearmor_pgp_key "$key_tmp" "$keyring"; then
        err "导入 ${label} GPG 密钥失败"
        return 1
    fi
    chmod 0644 "$keyring"
    printf '%s\n' "$source_line" > "$source_file"

    if ! apt-get update; then
        err "apt-get update 失败，请检查 ${label} 软件源配置"
        return 1
    fi
    return 0
}

setup_amd64_apt_repo() {
    setup_apt_repo \
        "XanMod 官方 (${OS_CODENAME})" \
        "https://dl.xanmod.org/archive.key" \
        "$XANMOD_KEYRING" \
        "deb [signed-by=${XANMOD_KEYRING}] http://deb.xanmod.org ${OS_CODENAME} main" \
        "$XANMOD_SOURCE_LIST"
}

setup_arm64_apt_repo() {
    setup_apt_repo \
        "XanMod ARM64 (GitHub Pages)" \
        "${ARM64_APT_URL}/archive.key" \
        "$ARM64_KEYRING" \
        "deb [signed-by=${ARM64_KEYRING} arch=arm64] ${ARM64_APT_URL} stable main" \
        "$ARM64_SOURCE_LIST"
}

install_apt_channel() {
    local ch="$1"
    local repo_arch="$2"
    local pkg="${CH_PKG_OR_TAG[$ch]}"
    local online_ver="${CH_ONLINE_VER[$ch]}"
    local installed_ver="${CH_INSTALLED_VER[$ch]}"
    local meta_installed="${CH_META_INSTALLED[$ch]}"
    local target_k="${CH_TARGET_KERNEL[$ch]}"

    local do_apt_install=1
    if [ -n "$meta_installed" ] && [ "$meta_installed" = "$online_ver" ]; then
        if [ -n "$target_k" ] && [ "$CURRENT_KERNEL" = "$target_k" ]; then
            ok "通道 ${ch^^} (${pkg}) 已安装最新版本 ${online_ver}，且当前正在运行该内核。"
            read -r -p "  是否仍要重新配置 GRUB 并确认启动项？[y/N]: " regrub
            if [[ ! "$regrub" =~ ^[Yy]$ ]]; then
                return 0
            fi
            do_apt_install=0
        else
            warn "通道 ${ch^^} (${pkg}) 已安装最新版本 ${online_ver}，但当前运行内核为 ${CURRENT_KERNEL}。"
            read -r -p "  是否直接将其设为 GRUB 默认启动项并重启生效？[Y/n]: " apply_grub
            if [[ "$apply_grub" =~ ^[Nn]$ ]]; then
                return 0
            fi
            do_apt_install=0
        fi
    else
        echo ""
        if [ -n "$meta_installed" ]; then
            info "准备将 ${C_BCYAN}${pkg}${C_RESET} 从 ${C_YELLOW}${meta_installed}${C_RESET} 升级至 ${C_BGREEN}${online_ver}${C_RESET}"
        elif [ -n "$installed_ver" ] && [ "$installed_ver" = "$target_k" ]; then
            info "本机已安装内核 ${C_BGREEN}${target_k}${C_RESET}，将配置 APT 源并安装元包 ${C_BCYAN}${pkg}${C_RESET} (${C_BGREEN}${online_ver}${C_RESET}) 纳入 apt 管理"
        elif [ -n "$installed_ver" ]; then
            info "准备安装元包 ${C_BCYAN}${pkg}${C_RESET} (${C_BGREEN}${online_ver}${C_RESET})，替换/升级同系内核 ${C_YELLOW}${installed_ver}${C_RESET}"
        else
            info "准备安装 ${C_BCYAN}${pkg}${C_RESET} (${C_BGREEN}${online_ver}${C_RESET})"
        fi
        read -r -p "  确认开始安装吗？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "已取消安装。"
            return 0
        fi
    fi

    if [ "$do_apt_install" -eq 1 ]; then
        if [ "$repo_arch" = "arm64" ]; then
            setup_arm64_apt_repo || return 1
        else
            setup_amd64_apt_repo || return 1
        fi
        echo ""
        info "正在安装 ${C_BGREEN}${pkg}${C_RESET} ..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            err "apt-get install $pkg 失败"
            return 1
        fi
    fi

    local post_deps=""
    post_deps=$(dpkg-query -W -f='${Depends}\n' "$pkg" 2>/dev/null || true)
    local detected_k=""
    detected_k=$(extract_image_krel_from_depends "$post_deps")
    target_k="${detected_k:-${target_k:-$(get_latest_xanmod_modules)}}"

    if [ -z "$target_k" ]; then
        err "未能确定新安装的 XanMod 内核版本号，无法配置 GRUB"
        return 1
    fi

    configure_grub_for_kernel "$target_k" || return 1
    prompt_enter_reboot "XanMod ${ch^^} (${target_k}) 安装与 GRUB 配置完成。"
}

install_amd64_channel() {
    install_apt_channel "$1" "amd64"
}

install_arm64_channel() {
    if [ "$ARM64_USE_APT" -eq 1 ]; then
        install_apt_channel "$1" "arm64"
        return $?
    fi
    local ch="$1"
    local tag="${CH_PKG_OR_TAG[$ch]}"
    local online_ver="${CH_ONLINE_VER[$ch]}"
    local installed_ver="${CH_INSTALLED_VER[$ch]}"
    local target_k="${CH_TARGET_KERNEL[$ch]}"

    local do_deb_install=1
    if [ -n "$installed_ver" ] && [ "$installed_ver" = "$target_k" ]; then
        if [ "$CURRENT_KERNEL" = "$target_k" ]; then
            ok "ARM64 ${ch^^} (${target_k}) 已安装并正在运行中。"
            read -r -p "  是否仍要重新下载校验并重装，或仅刷新 GRUB？[y=重装 / g=仅配置GRUB / N=返回]: " act
            case "$act" in
                [Yy]) do_deb_install=1 ;;
                [Gg]) do_deb_install=0 ;;
                *)    return 0 ;;
            esac
        else
            warn "ARM64 ${ch^^} (${target_k}) 已安装但当前未启用 (当前运行: ${CURRENT_KERNEL})。"
            read -r -p "  选择操作 [g=设为GRUB默认启动(推荐) / y=重新下载安装 / N=返回]: " act
            case "$act" in
                [Yy])   do_deb_install=1 ;;
                ""|[Gg]) do_deb_install=0 ;;
                *)      return 0 ;;
            esac
        fi
    else
        echo ""
        info "准备下载并安装 ARM64 ${C_BCYAN}${ch^^}${C_RESET} Release: ${C_BGREEN}${tag}${C_RESET}"
        echo -e "    ${C_DIM}目标内核:${C_RESET} ${C_BGREEN}${target_k}${C_RESET}"
        echo -e "    ${C_DIM}镜像包  :${C_RESET} ${CH_IMG_NAME[$ch]}"
        echo -e "    ${C_DIM}头文件包:${C_RESET} ${CH_HDR_NAME[$ch]}"
        read -r -p "  确认下载并安装吗？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "已取消安装。"
            return 0
        fi
    fi

    if [ "$do_deb_install" -eq 1 ]; then
        ensure_tmp_dir
        local dl_dir="${TMP_WORK_DIR}/arm64-${ch}"
        rm -rf "$dl_dir"
        mkdir -p "$dl_dir"
        chmod 0755 "$dl_dir"

        local img_file="${dl_dir}/${CH_IMG_NAME[$ch]}"
        local hdr_file="${dl_dir}/${CH_HDR_NAME[$ch]}"

        info "正在下载 ${CH_IMG_NAME[$ch]} ..."
        if ! http_get "${CH_IMG_URL[$ch]}" "$img_file" 600 0; then
            err "下载 linux-image deb 失败"
            return 1
        fi

        info "正在下载 ${CH_HDR_NAME[$ch]} ..."
        if ! http_get "${CH_HDR_URL[$ch]}" "$hdr_file" 600 0; then
            err "下载 linux-headers deb 失败"
            return 1
        fi

        if [ -n "${CH_SUM_URL[$ch]}" ]; then
            local sum_file="${dl_dir}/SHA256SUMS"
            info "正在下载并校验 SHA256SUMS ..."
            if ! http_get "${CH_SUM_URL[$ch]}" "$sum_file" 60 1; then
                err "下载 SHA256SUMS 失败"
                return 1
            fi
            if ! grep -Fq "${CH_IMG_NAME[$ch]}" "$sum_file" || ! grep -Fq "${CH_HDR_NAME[$ch]}" "$sum_file"; then
                err "SHA256SUMS 中缺少目标 deb 文件校验条目，已中止安装"
                return 1
            fi
            if ! (cd "$dl_dir" && sha256sum -c --ignore-missing SHA256SUMS); then
                err "SHA256 校验未通过，安装包可能损坏"
                return 1
            fi
            ok "SHA256 校验通过"
        else
            warn "该 Release 未提供 SHA256SUMS，跳过哈希校验"
        fi

        chmod 0644 "$img_file" "$hdr_file"
        local pkg_img_name=""
        pkg_img_name=$(dpkg-deb -f "$img_file" Package 2>/dev/null || true)
        if [[ "$pkg_img_name" == linux-image-* ]]; then
            target_k="${pkg_img_name#linux-image-}"
        fi

        echo ""
        info "正在安装 ARM64 内核包 (${target_k}) ..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$img_file" "$hdr_file"; then
            err "apt-get 安装 deb 包失败"
            return 1
        fi
    fi

    target_k="${target_k:-$(get_latest_xanmod_modules)}"
    if [ -z "$target_k" ]; then
        err "未能确定新安装的 ARM64 XanMod 内核版本号"
        return 1
    fi

    configure_grub_for_kernel "$target_k" || return 1
    prompt_enter_reboot "XanMod ARM64 ${ch^^} (${target_k}) 安装与 GRUB 配置完成。"
}

install_xanmod_menu() {
    echo ""
    probe_cpu_isa 1

    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
        echo ""
        err "当前系统架构 '${ARCH}' (${RAW_ARCH}) 暂不支持自动安装 XanMod 内核。"
        pause_continue
        return 1
    fi

    check_runtime_tools || { pause_continue; return 1; }

    local need_refresh=1
    while true; do
        if [ "$need_refresh" -eq 1 ]; then
            echo ""
            reset_channel_cache
            if [ "$ARCH" = "amd64" ]; then
                fetch_amd64_channels || { pause_continue "按回车键返回主菜单..."; return 1; }
            else
                fetch_arm64_channels || { pause_continue "按回车键返回主菜单..."; return 1; }
            fi
            need_refresh=0
        fi

        echo ""
        print_banner
        print_system_summary
        print_installed_xanmod_summary
        hr_thin
        echo -e "  ${C_BWHITE}可用 XanMod 内核版本 (架构: ${C_BCYAN}${ARCH_DISPLAY}${C_BWHITE} | 等级: ${C_BMAGENTA}${CPU_PSABI}${C_BWHITE})${C_RESET}"
        echo ""

        local idx=1 ch
        for ch in "${CHANNELS[@]}"; do
            local label color online_v inst_v target_k pkg_tag reason status_text
            label=$(channel_label "$ch")
            color=$(channel_color "$ch")
            online_v="${CH_ONLINE_VER[$ch]}"
            inst_v="${CH_INSTALLED_VER[$ch]}"
            target_k="${CH_TARGET_KERNEL[$ch]}"
            pkg_tag="${CH_PKG_OR_TAG[$ch]}"
            reason="${CH_UNAVAIL_REASON[$ch]}"

            if [ -n "$reason" ] || [ -z "$online_v" ]; then
                status_text="${C_RED}[不可用] ${reason:-未获取到版本}${C_RESET}"
                echo -e "  ${C_BOLD}${idx}.${C_RESET} ${color}${label}${C_RESET}"
                echo -e "     ${status_text}"
            else
                local state_badge=""
                local meta_inst="${CH_META_INSTALLED[$ch]}"
                if [ -n "$inst_v" ] && { [ "$inst_v" = "$online_v" ] || [ "$inst_v" = "$target_k" ]; }; then
                    if [ "$ARCH" = "arm64" ] && [ "$ARM64_USE_APT" -eq 1 ] && [ -z "$meta_inst" ]; then
                        state_badge="${C_BYELLOW}[已安装·未纳管元包]${C_RESET}"
                    elif [ -n "$target_k" ] && [ "$CURRENT_KERNEL" = "$target_k" ]; then
                        state_badge="${C_BGREEN}[已是最新且运行中]${C_RESET}"
                    else
                        state_badge="${C_BCYAN}[已是最新·未重启切换]${C_RESET}"
                    fi
                elif [ -n "$inst_v" ]; then
                    state_badge="${C_BYELLOW}[可升级: ${inst_v} -> ${online_v}]${C_RESET}"
                else
                    state_badge="${C_DIM}[未安装]${C_RESET}"
                fi

                echo -e "  ${C_BOLD}${idx}.${C_RESET} ${color}${label}${C_RESET}  ${state_badge}"
                if [ "$ARCH" = "amd64" ] || [ "$ARM64_USE_APT" -eq 1 ]; then
                    echo -e "     ${C_DIM}在线最新:${C_RESET} ${C_BGREEN}${online_v}${C_RESET}  ${C_DIM}| 元包:${C_RESET} ${pkg_tag}${target_k:+  ${C_DIM}| 内核:${C_RESET} ${target_k}}"
                else
                    echo -e "     ${C_DIM}在线最新:${C_RESET} ${C_BGREEN}${online_v}${C_RESET}  ${C_DIM}| Release:${C_RESET} ${pkg_tag}"
                fi
            fi
            echo ""
            idx=$((idx + 1))
        done

        echo -e "  ${C_BOLD}r.${C_RESET} ${C_CYAN}重新检测在线版本${C_RESET}"
        echo -e "  ${C_BOLD}0.${C_RESET} ${C_DIM}返回主菜单${C_RESET}"
        hr_thin

        local choice=""
        read -r -p "  请选择要安装的版本 [1-3 / r / 0]: " choice
        case "$choice" in
            1|2|3)
                local selected_ch="${CHANNELS[$((choice - 1))]}"
                if [ -n "${CH_UNAVAIL_REASON[$selected_ch]}" ] || [ -z "${CH_ONLINE_VER[$selected_ch]}" ]; then
                    warn "通道 ${selected_ch^^} 当前不可安装: ${CH_UNAVAIL_REASON[$selected_ch]:-未获取到在线版本}"
                    pause_continue "按回车键重新选择..."
                    continue
                fi
                if [ "$ARCH" = "amd64" ]; then
                    install_amd64_channel "$selected_ch"
                else
                    install_arm64_channel "$selected_ch"
                fi
                pause_continue "按回车键返回通道列表..."
                need_refresh=1
                ;;
            r|R)
                need_refresh=1
                ;;
            0|"")
                return 0
                ;;
            *)
                warn "无效输入: '$choice'，请输入 1、2、3、r 或 0"
                pause_continue
                ;;
        esac
    done
}

parse_depends_names() {
    local deps="$1"
    awk -F'[,|]' '{
        for (i = 1; i <= NF; i++) {
            s = $i
            gsub(/[[:space:]]*\([^)]*\)/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            if (s != "") {
                split(s, a, /[[:space:]]+/)
                if (a[1] != "") print a[1]
            }
        }
    }' <<< "$deps"
}

is_running_kernel_pkg() {
    local pkg="$1"
    local cur_k="$2"
    local kind
    for kind in image image-unsigned headers modules modules-extra modules-iwlwifi tools cloud-tools buildinfo kbuild; do
        case "$pkg" in
            "linux-${kind}-${cur_k}"|\
            "linux-${kind}-${cur_k}-dbg"|\
            "linux-${kind}-${cur_k}-common")
                return 0
                ;;
        esac
    done
    case "$pkg" in
        "proxmox-kernel-${cur_k}"|\
        "proxmox-headers-${cur_k}"|\
        "pve-kernel-${cur_k}"|\
        "pve-headers-${cur_k}")
            return 0
            ;;
    esac
    return 1
}

is_versioned_kernel_pkg() {
    local pkg="$1"
    case "$pkg" in
        linux-libc-dev|linux-libc-dev-*) return 1 ;;
    esac
    if [[ "$pkg" =~ ^linux-(image|image-unsigned|headers|modules|modules-extra|modules-iwlwifi|tools|cloud-tools|buildinfo|kbuild|source)-[0-9] ]]; then
        return 0
    fi
    if [[ "$pkg" =~ ^(proxmox-kernel|proxmox-headers|pve-kernel|pve-headers)-[0-9] ]]; then
        return 0
    fi
    return 1
}

is_kernel_metapkg() {
    local pkg="$1"
    local deps="${2:-}"
    is_versioned_kernel_pkg "$pkg" && return 1
    case "$pkg" in
        linux-libc-dev|linux-libc-dev-*|linux-base*|linux-doc*|linux-source*|linux-cpupower*|linux-sysctl*|linux-firmware*|*-common)
            return 1
            ;;
    esac
    if [[ "$pkg" =~ ^linux-xanmod(-edge|-lts)?(-x64v[1-3]|-arm64)?$ ]]; then
        return 0
    fi
    if [[ "$pkg" =~ ^(linux-image|linux-headers|linux-generic|linux-lowlatency|linux-virtual|linux-oem|linux-cloud|linux-rt|linux-aws|linux-azure|linux-gcp|linux-oracle|linux-zabbly|proxmox-default-kernel|pve-kernel) ]]; then
        return 0
    fi
    if [ -n "$deps" ] && [[ "$pkg" == linux-* || "$pkg" == proxmox-* || "$pkg" == pve-* ]]; then
        if grep -Eq '(^|[,|[:space:]])(linux-image(-unsigned)?-[0-9]|linux-headers-[0-9]|proxmox-kernel-[0-9]|pve-kernel-[0-9])' <<< "$deps"; then
            return 0
        fi
    fi
    return 1
}

parse_index_selection() {
    local input="$1"
    local max_idx="$2"
    local token a b i
    local -A seen=()
    local -a out=()

    for token in ${input//,/ }; do
        if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
            a="${token%-*}"
            b="${token#*-}"
            if [ "$a" -lt 1 ] || [ "$b" -gt "$max_idx" ] || [ "$a" -gt "$b" ]; then
                return 1
            fi
            for ((i = a; i <= b; i++)); do
                if [ -z "${seen[$i]:-}" ]; then
                    seen[$i]=1
                    out+=("$i")
                fi
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            if [ "$token" -lt 1 ] || [ "$token" -gt "$max_idx" ]; then
                return 1
            fi
            if [ -z "${seen[$token]:-}" ]; then
                seen[$token]=1
                out+=("$token")
            fi
        else
            return 1
        fi
    done

    [ "${#out[@]}" -gt 0 ] || return 1
    printf '%s\n' "${out[@]}"
}

get_pkg_cmp_version() {
    local pkg="$1"
    local raw_ver="$2"
    local v="${raw_ver#*:}"
    local pkg_num="" ver_core=""

    if [[ "$pkg" =~ (^|-)([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        pkg_num="${BASH_REMATCH[2]}"
    fi
    if [[ "$v" =~ ^([0-9]+(\.[0-9]+)*) ]]; then
        ver_core="${BASH_REMATCH[1]}"
    fi

    if [ -n "$ver_core" ] && dpkg --compare-versions "$ver_core" ge "2.6" 2>/dev/null && dpkg --compare-versions "$ver_core" lt "100.0" 2>/dev/null; then
        if [[ "$ver_core" =~ ^[0-9]+\.[0-9]+$ ]] && [ -n "$pkg_num" ] && [[ "$pkg_num" == "${ver_core}."* ]]; then
            echo "${pkg_num}-0"
            return 0
        fi
        echo "$v"
        return 0
    fi

    echo "${pkg_num:-$v}"
}

extract_ver_core() {
    local v="$1"
    local core=""
    if [[ "$v" =~ ^([0-9]+(\.[0-9]+)*) ]]; then
        core="${BASH_REMATCH[1]}"
    fi
    if [[ "$core" =~ ^[0-9]+\.[0-9]+$ ]]; then
        core="${core}.0"
    fi
    echo "$core"
}

extract_pkg_flavor() {
    local name="$1"
    sed -E 's/^(linux-(image-unsigned|image|headers|modules-extra|modules-iwlwifi|modules|tools|cloud-tools|buildinfo|kbuild)|proxmox-kernel|proxmox-headers|pve-kernel|pve-headers)-//; s/^[0-9]+(\.[0-9]+)*([-+][0-9]+)?//; s/^-//' <<< "$name"
}

compare_kernel_vs_running() {
    local cand_ver="$1"
    local cur_ver="$2"
    local cand_flavor="$3"
    local cur_flavor="$4"

    local cand_core cur_core
    cand_core=$(extract_ver_core "$cand_ver")
    cur_core=$(extract_ver_core "$cur_ver")

    if [ -z "$cand_core" ] || [ -z "$cur_core" ]; then
        echo "same"
        return 0
    fi

    if dpkg --compare-versions "$cand_core" gt "$cur_core" 2>/dev/null; then
        echo "newer"
        return 0
    fi
    if dpkg --compare-versions "$cand_core" lt "$cur_core" 2>/dev/null; then
        echo "older"
        return 0
    fi

    local cand_tail="${cand_ver#"${cand_core}"}"
    local cur_tail="${cur_ver#"${cur_core}"}"
    cand_tail="${cand_tail%~*}"
    cur_tail="${cur_tail%~*}"

    if { [ -n "$cand_flavor" ] && [ "$cand_flavor" = "$cur_flavor" ]; } || \
       { [[ "$cand_tail" =~ ^[.-]?[0-9]+([.+~-][0-9]+)*$ ]] && [[ "$cur_tail" =~ ^[.-]?[0-9]+([.+~-][0-9]+)*$ ]]; }; then
        if dpkg --compare-versions "$cand_ver" gt "$cur_ver" 2>/dev/null; then
            echo "newer"
        elif dpkg --compare-versions "$cand_ver" lt "$cur_ver" 2>/dev/null; then
            echo "older"
        else
            echo "same"
        fi
        return 0
    fi

    echo "same"
}

detect_grub_pending_kernel() {
    local grub_cfg="/boot/grub/grub.cfg"
    local grub_env="/boot/grub/grubenv"
    if [ ! -f "$grub_cfg" ] || [ ! -f "$grub_env" ] || ! command -v grub-editenv >/dev/null 2>&1; then
        return 0
    fi
    local saved_entry=""
    saved_entry=$(grub-editenv "$grub_env" list 2>/dev/null | sed -n 's/^saved_entry=//p')
    if [ -z "$saved_entry" ] || [[ "$saved_entry" == [0-9]* ]]; then
        return 0
    fi
    local leaf_id="${saved_entry##*>}"
    awk -v target_id="$leaf_id" '
        /^[[:space:]]*menuentry[[:space:]]/ {
            in_target = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /id_option$/ || $i == "--id") {
                    id = $(i + 1)
                    gsub(/['\''"]/, "", id)
                    if (id == target_id) in_target = 1
                }
            }
        }
        in_target && /vmlinuz-/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /vmlinuz-/) {
                    sub(/^.*vmlinuz-/, "", $i)
                    gsub(/['\''"]$/, "", $i)
                    print $i
                    exit
                }
            }
        }
        in_target && /^[[:space:]]*\}/ {
            in_target = 0
        }
    ' "$grub_cfg"
}

scan_installed_kernels() {
    local cur_k="$CURRENT_KERNEL"
    local cur_flavor
    cur_flavor=$(extract_pkg_flavor "linux-image-${cur_k}")

    local -a all_lines=()
    mapfile -t all_lines < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${Depends}\n' 'linux-*' 'proxmox-*' 'pve-*' 2>/dev/null || true)

    declare -A pkg_status pkg_ver pkg_deps protected_set installed_image_set
    local line st pkg ver deps

    for line in "${all_lines[@]}"; do
        IFS=$'\t' read -r st pkg ver deps <<< "$line"
        [ -n "$pkg" ] || continue
        pkg_status[$pkg]="$st"
        pkg_ver[$pkg]="$ver"
        pkg_deps[$pkg]="$deps"
        if [[ "$st" == ii* || "$st" == hi* ]]; then
            case "$pkg" in
                linux-image-[0-9]*)          installed_image_set[${pkg#linux-image-}]=1 ;;
                linux-image-unsigned-[0-9]*) installed_image_set[${pkg#linux-image-unsigned-}]=1 ;;
                proxmox-kernel-[0-9]*)       installed_image_set[${pkg#proxmox-kernel-}]=1 ;;
                pve-kernel-[0-9]*)           installed_image_set[${pkg#pve-kernel-}]=1 ;;
            esac
        fi
    done

    local cur_cmp_ver=""
    local cand_run
    for cand_run in "linux-image-${cur_k}" "linux-image-unsigned-${cur_k}" "proxmox-kernel-${cur_k}" "pve-kernel-${cur_k}"; do
        st="${pkg_status[$cand_run]:-}"
        if [[ "$st" == ii* || "$st" == hi* ]]; then
            cur_cmp_ver=$(get_pkg_cmp_version "$cand_run" "${pkg_ver[$cand_run]}")
            break
        fi
    done
    if [ -z "$cur_cmp_ver" ]; then
        cur_cmp_ver=$(get_pkg_cmp_version "linux-image-${cur_k}" "$cur_k")
    fi
    CUR_CMP_VER_DISPLAY="$cur_cmp_ver"

    local -a core_running=()
    for pkg in "${!pkg_status[@]}"; do
        st="${pkg_status[$pkg]}"
        [[ "$st" == ii* || "$st" == hi* ]] || continue
        if is_running_kernel_pkg "$pkg" "$cur_k"; then
            protected_set[$pkg]=1
            core_running+=("$pkg")
        fi
    done

    local dep
    for pkg in "${core_running[@]}"; do
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            if [[ "$dep" == linux-* || "$dep" == proxmox-* || "$dep" == pve-* ]] && [ -n "${pkg_status[$dep]:-}" ]; then
                protected_set[$dep]=1
            fi
        done < <(parse_depends_names "${pkg_deps[$pkg]}")
    done

    local _ changed=1
    for _ in 1 2 3; do
        [ "$changed" -eq 1 ] || break
        changed=0
        for pkg in "${!pkg_status[@]}"; do
            [ -n "${protected_set[$pkg]:-}" ] && continue
            st="${pkg_status[$pkg]}"
            [[ "$st" == ii* || "$st" == hi* ]] || continue
            is_kernel_metapkg "$pkg" "${pkg_deps[$pkg]}" || continue
            while IFS= read -r dep; do
                if [ -n "${protected_set[$dep]:-}" ]; then
                    if is_versioned_kernel_pkg "$dep" || is_kernel_metapkg "$dep" "${pkg_deps[$dep]:-}"; then
                        protected_set[$pkg]=1
                        changed=1
                        break
                    fi
                fi
            done < <(parse_depends_names "${pkg_deps[$pkg]}")
        done
    done

    GRUB_PENDING_KERNEL=$(detect_grub_pending_kernel)

    PROTECTED_RECORDS=()
    INACTIVE_PKGS=()
    INACTIVE_TYPES=()
    INACTIVE_VERS=()
    INACTIVE_NOTES=()
    INACTIVE_CLASSES=()
    UNMANAGED_NEWER_KERNELS=()
    UNMANAGED_OTHER_KERNELS=()

    for pkg in $(printf '%s\n' "${!pkg_status[@]}" | sort -V); do
        st="${pkg_status[$pkg]}"
        ver="${pkg_ver[$pkg]}"
        deps="${pkg_deps[$pkg]}"

        if is_versioned_kernel_pkg "$pkg"; then
            if [ -n "${protected_set[$pkg]:-}" ]; then
                PROTECTED_RECORDS+=("内核包"$'\t'"${pkg}"$'\t'"${ver}")
                continue
            fi

            if [[ "$st" == rc* ]]; then
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("残留配置")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("仅剩配置残留 (rc) · 可安全清理")
                INACTIVE_CLASSES+=("older")
            elif [[ "$st" == ii* || "$st" == hi* ]]; then
                local pkg_cmp cand_flavor rel_class note grub_hint=""
                pkg_cmp=$(get_pkg_cmp_version "$pkg" "$ver")
                cand_flavor=$(extract_pkg_flavor "$pkg")
                rel_class=$(compare_kernel_vs_running "$pkg_cmp" "$cur_cmp_ver" "$cand_flavor" "$cur_flavor")

                local pkg_krel=""
                case "$pkg" in
                    linux-image-[0-9]*)          pkg_krel="${pkg#linux-image-}" ;;
                    linux-image-unsigned-[0-9]*) pkg_krel="${pkg#linux-image-unsigned-}" ;;
                    proxmox-kernel-[0-9]*)       pkg_krel="${pkg#proxmox-kernel-}" ;;
                    pve-kernel-[0-9]*)           pkg_krel="${pkg#pve-kernel-}" ;;
                esac
                if [ -n "$pkg_krel" ] && [ -n "$GRUB_PENDING_KERNEL" ] && [ "$pkg_krel" = "$GRUB_PENDING_KERNEL" ]; then
                    grub_hint=" · GRUB默认下次启动"
                fi

                case "$rel_class" in
                    newer)
                        note="高于当前内核 · 尚未重启生效${grub_hint}"
                        ;;
                    older)
                        note="旧版本内核 · 可清理${grub_hint}"
                        ;;
                    *)
                        note="同版本其它分支/构建${grub_hint}"
                        ;;
                esac
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("内核包")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("$note")
                INACTIVE_CLASSES+=("$rel_class")
            fi
        elif is_kernel_metapkg "$pkg" "$deps"; then
            if [ -n "${protected_set[$pkg]:-}" ]; then
                PROTECTED_RECORDS+=("元包"$'\t'"${pkg}"$'\t'"${ver}")
                continue
            fi

            if [[ "$st" == rc* ]]; then
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("残留元包")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("元包残留配置 (rc) · 可安全清理")
                INACTIVE_CLASSES+=("older")
            elif [[ "$st" == ii* || "$st" == hi* ]]; then
                local target_ref="" target_pkg="" meta_cmp="" cand_flavor="" rel_class=""
                target_ref=$(extract_image_krel_from_depends "$deps")
                while IFS= read -r dep; do
                    if is_versioned_kernel_pkg "$dep" && [ -n "${pkg_ver[$dep]:-}" ]; then
                        target_pkg="$dep"
                        break
                    fi
                done < <(parse_depends_names "$deps")

                if [ -n "$target_pkg" ]; then
                    meta_cmp=$(get_pkg_cmp_version "$target_pkg" "${pkg_ver[$target_pkg]}")
                    cand_flavor=$(extract_pkg_flavor "$target_pkg")
                else
                    meta_cmp=$(get_pkg_cmp_version "$pkg" "$ver")
                    cand_flavor=""
                fi
                rel_class=$(compare_kernel_vs_running "$meta_cmp" "$cur_cmp_ver" "$cand_flavor" "$cur_flavor")

                local note=""
                case "$rel_class" in
                    newer) note="未启用元包 · 指向更高版本${target_ref:+ (${target_ref})} (待重启)" ;;
                    older) note="未启用旧元包${target_ref:+ (指向 ${target_ref})}" ;;
                    *)     note="未启用元包 · 其它分支${target_ref:+ (${target_ref})}" ;;
                esac
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("元包")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("$note")
                INACTIVE_CLASSES+=("$rel_class")
            fi
        fi
    done

    if [ -d /lib/modules ]; then
        local mod_dir="" mod_cmp="" mod_flavor="" mod_rel=""
        for mod_dir in $(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V); do
            [ "$mod_dir" = "$cur_k" ] && continue
            [[ "$mod_dir" =~ ^[0-9]+\.[0-9]+ ]] || continue
            [ -n "${installed_image_set[$mod_dir]:-}" ] && continue
            mod_cmp=$(get_pkg_cmp_version "linux-image-${mod_dir}" "$mod_dir")
            mod_flavor=$(extract_pkg_flavor "linux-image-${mod_dir}")
            mod_rel=$(compare_kernel_vs_running "$mod_cmp" "$cur_cmp_ver" "$mod_flavor" "$cur_flavor")
            if [ "$mod_rel" = "newer" ]; then
                UNMANAGED_NEWER_KERNELS+=("$mod_dir")
            else
                UNMANAGED_OTHER_KERNELS+=("$mod_dir")
            fi
        done
    fi

    CLEANUP_PROTECTED_PKGS=("${!protected_set[@]}")
}

cleanup_old_kernels_menu() {
    local -a PROTECTED_RECORDS=() CLEANUP_PROTECTED_PKGS=()
    local -a INACTIVE_PKGS=() INACTIVE_TYPES=() INACTIVE_VERS=() INACTIVE_NOTES=() INACTIVE_CLASSES=()
    local -a UNMANAGED_NEWER_KERNELS=() UNMANAGED_OTHER_KERNELS=()
    local CUR_CMP_VER_DISPLAY="" GRUB_PENDING_KERNEL=""

    scan_installed_kernels

    echo ""
    print_banner
    print_system_summary

    echo -e "  ${C_BGREEN}▶ 当前运行内核与关联包 (受保护，不可删除)${C_RESET}"
    echo -e "    ${C_DIM}当前运行内核:${C_RESET} ${C_BGREEN}${CURRENT_KERNEL}${C_RESET}  ${C_DIM}(比较基准: ${CUR_CMP_VER_DISPLAY})${C_RESET}"
    if [ "${#PROTECTED_RECORDS[@]}" -eq 0 ]; then
        warn "dpkg 中无当前内核 '${CURRENT_KERNEL}' 的包记录 (可能为手动编译安装或容器内核)"
    else
        local rec r_type r_pkg r_ver r_tag
        for rec in "${PROTECTED_RECORDS[@]}"; do
            IFS=$'\t' read -r r_type r_pkg r_ver <<< "$rec"
            if [ "$r_type" = "元包" ]; then
                r_tag="[受保护·元包  ]"
            else
                r_tag="[受保护·内核包]"
            fi
            printf "    ${C_GREEN}%s${C_RESET} ${C_BWHITE}%-36s${C_RESET}  ${C_DIM}版本:${C_RESET} ${C_GREEN}%s${C_RESET}\n" \
                "$r_tag" "$r_pkg" "$r_ver"
        done
    fi

    local total="${#INACTIVE_PKGS[@]}"
    local old_count=0 newer_count=0 same_count=0 i
    for ((i = 0; i < total; i++)); do
        case "${INACTIVE_CLASSES[$i]}" in
            older) old_count=$((old_count + 1)) ;;
            newer) newer_count=$((newer_count + 1)) ;;
            *)     same_count=$((same_count + 1)) ;;
        esac
    done

    if [ "$newer_count" -gt 0 ] || [ "${#UNMANAGED_NEWER_KERNELS[@]}" -gt 0 ]; then
        echo ""
        echo -e "  ${C_BYELLOW}提醒: 已安装高于当前运行内核 (${CURRENT_KERNEL}) 的版本，尚未重启生效：${C_RESET}"
        for ((i = 0; i < total; i++)); do
            if [ "${INACTIVE_CLASSES[$i]}" = "newer" ] && [[ "${INACTIVE_PKGS[$i]}" =~ ^(linux-image|proxmox-kernel|pve-kernel) ]]; then
                echo -e "    ${C_BCYAN}•${C_RESET} ${C_BWHITE}${INACTIVE_PKGS[$i]}${C_RESET}  ${C_DIM}版本:${C_RESET} ${C_BGREEN}${INACTIVE_VERS[$i]}${C_RESET}"
            fi
        done
        local uk
        for uk in "${UNMANAGED_NEWER_KERNELS[@]}"; do
            echo -e "    ${C_BCYAN}•${C_RESET} ${C_BWHITE}/lib/modules/${uk}${C_RESET}  ${C_DIM}(非 dpkg 管理内核，待重启生效)${C_RESET}"
        done
        echo -e "    ${C_DIM}建议: 先重启进入新内核，再清理旧内核 (${CURRENT_KERNEL})。${C_RESET}"
    fi

    echo ""
    hr_thin
    echo -e "  ${C_BYELLOW}▶ 其它已安装但当前未启用的内核包与元包${C_RESET}"
    echo ""

    if [ "$total" -eq 0 ]; then
        if [ "${#UNMANAGED_OTHER_KERNELS[@]}" -gt 0 ]; then
            warn "dpkg 中无未启用内核包，但 /lib/modules 下存在未由 dpkg 管理的内核目录: ${UNMANAGED_OTHER_KERNELS[*]}"
        elif [ "${#UNMANAGED_NEWER_KERNELS[@]}" -gt 0 ]; then
            info "dpkg 中无旧内核包；可直接重启以切换至上述新内核。"
        else
            ok "未检测到可清理的未启用内核包或元包。"
        fi
        pause_continue "按回车键返回主菜单..."
        return 0
    fi

    printf "  ${C_DIM}%s %s  %-36s %-32s %s${C_RESET}\n" "编号" "类别    " "软件包名称                          " "版本号                          " "状态说明"
    hr_thin

    for ((i = 0; i < total; i++)); do
        local num=$((i + 1))
        local p_type="${INACTIVE_TYPES[$i]}"
        local p_name="${INACTIVE_PKGS[$i]}"
        local p_ver="${INACTIVE_VERS[$i]}"
        local p_note="${INACTIVE_NOTES[$i]}"
        local p_class="${INACTIVE_CLASSES[$i]}"

        local type_color="$C_BYELLOW"
        local note_color="$C_YELLOW"
        local p_type_col="$p_type"
        case "$p_type" in
            "内核包")   p_type_col="内核包  " ;;
            "元包")     p_type_col="元包    "; type_color="$C_BMAGENTA" ;;
            "残留元包") p_type_col="残留元包"; type_color="$C_BMAGENTA" ;;
            "残留配置") p_type_col="残留配置"; type_color="$C_DIM" ;;
        esac
        case "$p_class" in
            newer) note_color="$C_BCYAN" ;;
            same)  note_color="$C_MAGENTA" ;;
            older) note_color="$C_BYELLOW" ;;
        esac

        printf "  ${C_BOLD}[%2d]${C_RESET} ${type_color}%s${C_RESET}  ${C_BWHITE}%-36s${C_RESET} ${C_YELLOW}%-32s${C_RESET} ${note_color}%s${C_RESET}\n" \
            "$num" "$p_type_col" "$p_name" "$p_ver" "$p_note"
    done

    if [ "${#UNMANAGED_OTHER_KERNELS[@]}" -gt 0 ]; then
        echo ""
        echo -e "  ${C_DIM}注: 另有未由 dpkg 管理的内核模块目录 (/lib/modules): ${UNMANAGED_OTHER_KERNELS[*]} (脚本不自动移除手动编译内核)${C_RESET}"
    fi

    echo ""
    hr_thin
    if [ "$old_count" -gt 0 ]; then
        echo -e "  ${C_BOLD}o.${C_RESET} ${C_BGREEN}仅清理旧版本与残留配置 (${old_count} 项)${C_RESET} ${C_DIM}(跳过新版本与同版本其它分支)${C_RESET}"
    else
        echo -e "  ${C_DIM}说明: 当前无低于运行内核 (${CURRENT_KERNEL}) 的旧版本包。${C_RESET}"
    fi
    if [ "$newer_count" -gt 0 ]; then
        echo -e "  ${C_BOLD}r.${C_RESET} ${C_BCYAN}暂不清理，立即重启以切换至新内核${C_RESET}"
        echo -e "  ${C_BOLD}a.${C_RESET} ${C_BRED}清理以上全部未启用项 (包含未重启的新版本内核)${C_RESET}"
    else
        echo -e "  ${C_BOLD}a.${C_RESET} ${C_BYELLOW}清理以上全部未启用内核包与元包${C_RESET}"
    fi
    echo -e "  ${C_BOLD}编号${C_RESET} ${C_DIM}按编号选择清理 (例: 1 3 或 1-4)${C_RESET}"
    echo -e "  ${C_BOLD}0.${C_RESET} ${C_DIM}取消并返回主菜单${C_RESET}"
    echo ""

    local sel="" prompt_opts=""
    if [ "$old_count" -gt 0 ] && [ "$newer_count" -gt 0 ]; then
        prompt_opts="o / r / a / 序号 / 0"
    elif [ "$old_count" -gt 0 ]; then
        prompt_opts="o / a / 序号 / 0"
    elif [ "$newer_count" -gt 0 ]; then
        prompt_opts="r / a / 序号 / 0"
    else
        prompt_opts="a / 序号 / 0"
    fi

    local -a selected_indices=()
    read -r -p "  请选择操作 [${prompt_opts}]: " sel
    case "$sel" in
        0|"")
            info "已取消清理。"
            return 0
            ;;
        r|R)
            prompt_enter_reboot "已放弃清理操作，准备重启系统以切换内核！"
            return 0
            ;;
        o|O)
            for ((i = 0; i < total; i++)); do
                if [ "${INACTIVE_CLASSES[$i]}" = "older" ]; then
                    selected_indices+=("$((i + 1))")
                fi
            done
            if [ "${#selected_indices[@]}" -eq 0 ]; then
                warn "没有符合 [旧版本/残留配置] 条件的软件包。"
                pause_continue "按回车键返回主菜单..."
                return 0
            fi
            ;;
        a|A)
            for ((i = 0; i < total; i++)); do
                selected_indices+=("$((i + 1))")
            done
            ;;
        *)
            if ! mapfile -t selected_indices < <(parse_index_selection "$sel" "$total"); then
                err "输入格式无效或编号越界: '$sel'"
                pause_continue "按回车键返回主菜单..."
                return 1
            fi
            ;;
    esac

    local -a purge_pkgs=() newer_selected_msgs=()
    local -A prot_map=()
    local p s_idx arr_i
    for p in "${CLEANUP_PROTECTED_PKGS[@]}"; do
        prot_map[$p]=1
    done

    echo ""
    echo -e "  ${C_BRED}将执行 apt purge 卸载以下 ${#selected_indices[@]} 个软件包/元包:${C_RESET}"
    for s_idx in "${selected_indices[@]}"; do
        arr_i=$((s_idx - 1))
        p="${INACTIVE_PKGS[$arr_i]}"
        if [ -n "${prot_map[$p]:-}" ]; then
            err "已拦截: ${p} 为当前运行内核关联包，不可卸载"
            return 1
        fi
        purge_pkgs+=("$p")
        if [ "${INACTIVE_CLASSES[$arr_i]}" = "newer" ]; then
            newer_selected_msgs+=("${p} (版本: ${INACTIVE_VERS[$arr_i]})")
        fi
        echo -e "    ${C_RED}✖${C_RESET} ${C_BWHITE}${p}${C_RESET}  ${C_DIM}(版本: ${C_YELLOW}${INACTIVE_VERS[$arr_i]}${C_DIM} | ${INACTIVE_TYPES[$arr_i]})${C_RESET}"
    done

    if [ "${#newer_selected_msgs[@]}" -gt 0 ]; then
        echo ""
        warn "所选列表包含高于当前运行内核 (${CURRENT_KERNEL}) 的版本:"
        local nm
        for nm in "${newer_selected_msgs[@]}"; do
            echo -e "    ${C_BCYAN}• ${nm}${C_RESET}"
        done
        read -r -p "  卸载后重启将无法使用以上新内核，确认继续卸载？[y/N]: " confirm_newer
        if [[ ! "$confirm_newer" =~ ^[Yy]$ ]]; then
            info "已取消清理。"
            return 0
        fi
    else
        echo ""
        read -r -p "  确认卸载以上软件包并执行 autoremove --purge？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "已取消清理。"
            return 0
        fi
    fi

    echo ""
    info "正在执行 apt purge..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y "${purge_pkgs[@]}"; then
        err "apt-get purge 执行失败，请检查依赖或 dpkg 状态"
        pause_continue
        return 1
    fi

    info "正在执行 autoremove --purge..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || warn "autoremove 返回非零状态"

    if command -v update-grub >/dev/null 2>&1 && [ -d /boot/grub ]; then
        info "正在更新 GRUB 配置..."
        if update-grub; then
            if [ -f /boot/grub/grub.cfg ] && [ -f /boot/grub/grubenv ]; then
                local saved_entry=""
                saved_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
                if [ -n "$saved_entry" ] && [[ "$saved_entry" != [0-9]* ]]; then
                    local leaf_id="${saved_entry##*>}"
                    if ! grep -Fq -- "$leaf_id" /boot/grub/grub.cfg; then
                        warn "原 GRUB 默认启动项已被移除，正在重新指向当前运行内核 (${CURRENT_KERNEL})..."
                        configure_grub_for_kernel "$CURRENT_KERNEL" || warn "更新 GRUB 默认启动项失败，请手动检查"
                    fi
                fi
            fi
        else
            warn "update-grub 执行失败，重启前请手动检查 GRUB 配置"
        fi
    fi

    prompt_enter_reboot "旧内核清理完成。"
}

main_menu() {
    while true; do
        echo ""
        print_banner
        print_system_summary
        echo -e "  ${C_BWHITE}操作菜单:${C_RESET}"
        echo ""
        echo -e "    ${C_BOLD}1.${C_RESET} ${C_BGREEN}XanMod 内核安装${C_RESET}   ${C_DIM}(检测架构与可用版本并安装)${C_RESET}"
        echo -e "    ${C_BOLD}2.${C_RESET} ${C_BYELLOW}旧内核清理${C_RESET}        ${C_DIM}(检测运行内核、新旧内核与元包版本并清理)${C_RESET}"
        echo -e "    ${C_BOLD}3.${C_RESET} ${C_DIM}退出${C_RESET}"
        echo ""
        hr

        local opt=""
        read -r -p "  请输入选项 [1-3]: " opt
        case "$opt" in
            1)
                install_xanmod_menu
                ;;
            2)
                cleanup_old_kernels_menu
                ;;
            3|q|Q|0)
                echo ""
                info "已退出。"
                exit 0
                ;;
            *)
                warn "无效选项: '$opt'，请输入 1、2 或 3"
                ;;
        esac
    done
}

main() {
    init_colors
    trap cleanup_tmp EXIT
    require_root
    detect_system_info
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
