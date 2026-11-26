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
HTTP_LAST_ERROR=""
XANMOD_APT_BASE="https://deb.xanmod.org"

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

term_rule_width() {
    local cols="${COLUMNS:-}"
    if [ -z "$cols" ] && command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null || true)
    fi
    if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
        cols=38
    fi
    if [ "$cols" -lt 28 ]; then
        cols=28
    elif [ "$cols" -gt 46 ]; then
        cols=46
    fi
    printf '%s' "$cols"
}

draw_rule() {
    local color="$1"
    local ch="$2"
    local w="" line=""
    w=$(term_rule_width)
    printf -v line '%*s' "$w" ''
    line="${line// /$ch}"
    echo -e "${color}${line}${C_RESET}"
}

hr() {
    draw_rule "$C_BLUE" "━"
}

hr_thin() {
    draw_rule "$C_DIM" "─"
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

normalize_input() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v//０/0}"
    v="${v//１/1}"
    v="${v//２/2}"
    v="${v//３/3}"
    v="${v//４/4}"
    v="${v//５/5}"
    v="${v//６/6}"
    v="${v//７/7}"
    v="${v//８/8}"
    v="${v//９/9}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

flush_tty_input() {
    [ -t 0 ] || return 0
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)' 2>/dev/null || true
        return 0
    fi
    local saved_stty=""
    saved_stty=$(stty -g 2>/dev/null || true)
    if [ -n "$saved_stty" ]; then
        stty -icanon -echo min 0 time 0 2>/dev/null || true
        while IFS= read -r -t 0.01 -n 4096 _ 2>/dev/null; do :; done
        stty "$saved_stty" 2>/dev/null || true
    fi
}

read_input() {
    local out_var="$1"
    local prompt_str="$2"
    local raw=""
    printf '%b' "$prompt_str"
    if ! IFS= read -r raw; then
        printf -v "$out_var" '%s' ""
        return 1
    fi
    printf -v "$out_var" '%s' "$(normalize_input "$raw")"
    return 0
}

prompt_binary_menu() {
    local opt1="$1"
    local opt2="$2"
    local pick=""
    echo ""
    echo -e "  ${C_BOLD}1.${C_RESET} ${opt1}"
    echo -e "  ${C_BOLD}0.${C_RESET} ${opt2}"
    while true; do
        read_input pick "  请选择: " || return 1
        case "$pick" in
            "") continue ;;
            1)  return 0 ;;
            0)  return 1 ;;
            *)  warn "无效选项: ${pick}" ;;
        esac
    done
}

pause_continue() {
    local msg="${1:-按回车继续...}"
    local dummy=""
    echo ""
    read_input dummy "  ${C_DIM}${msg}${C_RESET} " || true
}

prompt_enter_reboot() {
    local reason="$1"
    local dummy=""
    echo ""
    hr
    ok "$reason"
    echo -e "  ${C_BYELLOW}按回车立即重启，Ctrl+C 取消${C_RESET}"
    flush_tty_input
    read_input dummy "  > " || return 0
    cleanup_tmp
    info "正在重启系统..."
    reboot || /sbin/reboot || systemctl reboot || die "执行重启失败，请手动执行 reboot"
}

print_banner() {
    echo ""
    hr
    echo -e "  ${C_BCYAN}XanMod 内核管理${C_RESET}"
    hr
}

print_system_summary() {
    local kernel_color="$C_BYELLOW"
    if [[ "$CURRENT_KERNEL" == *xanmod* ]]; then
        kernel_color="$C_BGREEN"
    fi

    echo -e "  ${C_DIM}内核:${C_RESET} ${kernel_color}${CURRENT_KERNEL}${C_RESET}"
    echo -e "  ${C_DIM}架构:${C_RESET} ${C_BCYAN}${ARCH_DISPLAY}${C_RESET} / ${C_BMAGENTA}${CPU_PSABI}${C_RESET}"
    echo -e "  ${C_DIM}系统:${C_RESET} ${C_BWHITE}${OS_PRETTY_NAME}${C_RESET}"
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
        ARCH_DISPLAY="x86_64"
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
                CPU_HW_NOTE="仅 LTS 支持 x64v1"
                ;;
        esac

        if [ "$verbose" -eq 1 ]; then
            [ -n "$CPU_MODEL" ] && echo -e "  ${C_DIM}处理器:${C_RESET} ${C_BWHITE}${CPU_MODEL}${C_RESET}"
            echo -e "  ${C_DIM}指令集:${C_RESET} ${C_BMAGENTA}${CPU_PSABI}${C_RESET} / ${XANMOD_TIER}"
            [ -n "$CPU_HW_NOTE" ] && echo -e "  ${C_DIM}说明:${C_RESET} ${C_BCYAN}${CPU_HW_NOTE}${C_RESET}"
        fi
    elif [ "$ARCH" = "arm64" ]; then
        ARCH_DISPLAY="arm64"
        CPU_PSABI="arm64"
        XANMOD_TIER="arm64"
        if [ "$verbose" -eq 1 ]; then
            echo -e "  ${C_DIM}架构:${C_RESET} ${C_BCYAN}arm64${C_RESET}"
        fi
    else
        ARCH_DISPLAY="$ARCH"
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

    HTTP_LAST_ERROR=""
    rm -f "$dest"

    local err_file="" rc=1 flag=""
    err_file=$(mktemp 2>/dev/null || echo "")

    if command -v curl >/dev/null 2>&1; then
        for flag in "" "-4" "-6"; do
            rm -f "$dest"
            local -a curl_opts=(-fL --retry 2 --retry-delay 1 --connect-timeout 12 --max-time "$max_time")
            [ -n "$flag" ] && curl_opts+=("$flag")
            if [ "$quiet" -eq 1 ]; then
                curl_opts+=(-sS)
                if [ -n "$err_file" ]; then
                    if curl "${curl_opts[@]}" -o "$dest" "$url" </dev/null 2>"$err_file" && [ -s "$dest" ]; then
                        rm -f "$err_file"
                        return 0
                    fi
                    rc=$?
                    HTTP_LAST_ERROR=$(tr '\r\n' ' ' < "$err_file" | sed 's/[[:space:]]*$//')
                elif curl "${curl_opts[@]}" -o "$dest" "$url" </dev/null 2>/dev/null && [ -s "$dest" ]; then
                    return 0
                fi
            else
                if curl "${curl_opts[@]}" -o "$dest" "$url" </dev/null && [ -s "$dest" ]; then
                    [ -n "$err_file" ] && rm -f "$err_file"
                    return 0
                fi
                rc=$?
            fi
        done
    fi

    if command -v wget >/dev/null 2>&1; then
        for flag in "" "-4"; do
            rm -f "$dest"
            local -a wget_opts=(--timeout=25 --tries=2 -O "$dest")
            [ -n "$flag" ] && wget_opts+=("$flag")
            if [ "$quiet" -eq 1 ]; then
                if [ -n "$err_file" ]; then
                    if wget -q "${wget_opts[@]}" "$url" </dev/null 2>"$err_file" && [ -s "$dest" ]; then
                        rm -f "$err_file"
                        return 0
                    fi
                    [ -s "$err_file" ] && HTTP_LAST_ERROR=$(tail -n1 "$err_file" | tr -d '\r')
                elif wget -q "${wget_opts[@]}" "$url" </dev/null 2>/dev/null && [ -s "$dest" ]; then
                    return 0
                fi
            else
                if { wget --show-progress "${wget_opts[@]}" "$url" </dev/null || wget "${wget_opts[@]}" "$url" </dev/null; } && [ -s "$dest" ]; then
                    [ -n "$err_file" ] && rm -f "$err_file"
                    return 0
                fi
            fi
        done
    fi

    if command -v python3 >/dev/null 2>&1; then
        rm -f "$dest"
        if python3 - "$url" "$dest" "$max_time" 2>"${err_file:-/dev/null}" << 'PY_EOF' && [ -s "$dest" ]; then
import sys, urllib.request, shutil
url, dest, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
req = urllib.request.Request(url, headers={"User-Agent": "xanmod-install"})
with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f:
    shutil.copyfileobj(r, f)
PY_EOF
            [ -n "$err_file" ] && rm -f "$err_file"
            return 0
        fi
        [ -n "$err_file" ] && [ -s "$err_file" ] && HTTP_LAST_ERROR=$(tail -n1 "$err_file" | tr -d '\r')
    fi

    if [ -x /usr/lib/apt/apt-helper ]; then
        rm -f "$dest"
        if /usr/lib/apt/apt-helper -q download-file "$url" "$dest" </dev/null >/dev/null 2>&1 && [ -s "$dest" ]; then
            [ -n "$err_file" ] && rm -f "$err_file"
            return 0
        fi
        rm -f "$dest"
        if [ "$quiet" -eq 1 ]; then
            if /usr/lib/apt/apt-helper -q -o APT::Sandbox::User=root download-file "$url" "$dest" </dev/null >/dev/null 2>"${err_file:-/dev/null}" && [ -s "$dest" ]; then
                [ -n "$err_file" ] && rm -f "$err_file"
                return 0
            fi
            [ -n "$err_file" ] && [ -s "$err_file" ] && HTTP_LAST_ERROR=$(tail -n1 "$err_file" | tr -d '\r')
        else
            if /usr/lib/apt/apt-helper -o APT::Sandbox::User=root download-file "$url" "$dest" </dev/null && [ -s "$dest" ]; then
                [ -n "$err_file" ] && rm -f "$err_file"
                return 0
            fi
        fi
    fi

    [ -n "$err_file" ] && rm -f "$err_file"
    rm -f "$dest"
    return "${rc:-1}"
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
        main) echo "MAIN 主线版" ;;
        edge) echo "EDGE 前沿版" ;;
        lts)  echo "LTS  长期版" ;;
        *)    echo "$1" ;;
    esac
}

short_ver_display() {
    local v="$1"
    v="${v%%~*}"
    v="${v%-0}"
    printf '%s' "$v"
}

extract_pkg_krel() {
    case "$1" in
        linux-image-[0-9]*)          printf '%s' "${1#linux-image-}" ;;
        linux-image-unsigned-[0-9]*) printf '%s' "${1#linux-image-unsigned-}" ;;
        proxmox-kernel-[0-9]*)       printf '%s' "${1#proxmox-kernel-}" ;;
        pve-kernel-[0-9]*)           printf '%s' "${1#pve-kernel-}" ;;
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
    if ! update-grub </dev/null; then
        err "update-grub 执行失败"
        return 1
    fi

    if [ ! -f "$grub_cfg" ]; then
        err "未找到 GRUB 配置文件: $grub_cfg"
        return 1
    fi

    local grub_id=""
    grub_id=$(extract_grub_menu_id "$target_kernel" "$grub_cfg")
    if [ -z "$grub_id" ]; then
        err "未提取到内核 ${target_kernel} 的启动项 ID"
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

    if ! grub-set-default "$grub_id" </dev/null; then
        err "grub-set-default 设置失败"
        return 1
    fi

    local saved_entry=""
    saved_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
    if [ "$saved_entry" != "$grub_id" ]; then
        err "GRUB 默认项校验失败: ${saved_entry:-空}"
        return 1
    fi

    if ! update-grub </dev/null >/dev/null 2>&1; then
        warn "最终 update-grub 返回异常，请检查 GRUB"
    fi

    echo ""
    hr_thin
    echo -e "  ${C_BGREEN}GRUB 配置完成${C_RESET}"
    echo -e "  ${C_DIM}默认内核:${C_RESET} ${C_BGREEN}${target_kernel}${C_RESET}"
    echo -e "  ${C_DIM}启动项ID:${C_RESET} ${C_BCYAN}${grub_id}${C_RESET}"
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

get_metapkg_owned_kernels() {
    local exclude_pkg="${1:-}"
    local st="" pkg="" deps="" krel=""
    while IFS=$'\t' read -r st pkg deps; do
        [ -n "$pkg" ] || continue
        [ "$pkg" = "$exclude_pkg" ] && continue
        if [[ "$st" == ii* || "$st" == hi* ]]; then
            krel=$(extract_image_krel_from_depends "$deps")
            [ -n "$krel" ] && printf '%s\n' "$krel"
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Depends}\n' 'linux-xanmod*' 2>/dev/null || true)
}

resolve_unmanaged_channel_install() {
    local ch="$1"
    local installed_imgs="$2"
    local excluded_imgs="$3"
    local target_k="${CH_TARGET_KERNEL[$ch]:-}"
    [ -n "$target_k" ] || return 0

    if { grep -Fxq "$target_k" <<< "$installed_imgs" || [ -d "/lib/modules/${target_k}" ]; } && \
       ! grep -Fxq "$target_k" <<< "$excluded_imgs"; then
        CH_INSTALLED_VER[$ch]="$target_k"
        return 0
    fi

    [ -n "$installed_imgs" ] || return 0
    local online_mm=""
    if [[ "$target_k" =~ ^([0-9]+\.[0-9]+)\. ]]; then
        online_mm="${BASH_REMATCH[1]}"
    fi
    [ -n "$online_mm" ] || return 0

    local cand="" rel="" best=""
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        grep -Fxq "$cand" <<< "$excluded_imgs" && continue
        rel=$(compare_kernel_vs_running "$(get_pkg_cmp_version "linux-image-${target_k}" "$target_k")" "$(get_pkg_cmp_version "linux-image-${cand}" "$cand")" "$(extract_pkg_flavor "linux-image-${target_k}")" "$(extract_pkg_flavor "linux-image-${cand}")")
        if [ "$rel" = "newer" ]; then
            best="$cand"
        fi
    done < <(grep -E "^${online_mm}\." <<< "$installed_imgs" | sort -V || true)

    [ -n "$best" ] && CH_INSTALLED_VER[$ch]="$best"
    return 0
}

resolve_all_unmanaged_channels() {
    local installed_imgs="$1"
    [ -n "$installed_imgs" ] || return 0

    local meta_owned="" ch
    meta_owned=$(get_metapkg_owned_kernels)
    for ch in "${CHANNELS[@]}"; do
        [ -n "${CH_META_INSTALLED[$ch]:-}" ] && continue
        [ -n "${CH_TARGET_KERNEL[$ch]:-}" ] || continue
        local excluded="$meta_owned" other_ch
        for other_ch in "${CHANNELS[@]}"; do
            [ "$other_ch" = "$ch" ] && continue
            [ -n "${CH_TARGET_KERNEL[$other_ch]:-}" ] && excluded="${excluded}"$'\n'"${CH_TARGET_KERNEL[$other_ch]}"
        done
        resolve_unmanaged_channel_install "$ch" "$installed_imgs" "$excluded"
    done
}

record_apt_metapkg_state() {
    local ch="$1"
    local pkg="$2"
    local repo_txt="$3"
    local missing_msg="$4"

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
    local repo_url="" fetched_base=""
    local -a base_candidates=()
    if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
        base_candidates=("https://deb.xanmod.org" "http://deb.xanmod.org")
    else
        base_candidates=("http://deb.xanmod.org" "https://deb.xanmod.org")
    fi

    info "正在检测 XanMod 官方源 (${OS_CODENAME} / ${CPU_PSABI})..."
    local base_cand=""
    for base_cand in "${base_candidates[@]}"; do
        repo_url="${base_cand}/dists/${OS_CODENAME}/main/binary-amd64/Packages.gz"
        if http_get "$repo_url" "$repo_gz" 30 1 && gzip -dc "$repo_gz" > "$repo_txt" 2>/dev/null && [ -s "$repo_txt" ]; then
            fetched_base="$base_cand"
            break
        fi
    done

    if [ -z "$fetched_base" ]; then
        err "无法获取 XanMod 官方源索引 (${OS_CODENAME})"
        [ -n "$HTTP_LAST_ERROR" ] && err "详情: ${HTTP_LAST_ERROR}"
        err "提示: 请检查网络或确认支持发行版代号 ${OS_CODENAME}"
        return 1
    fi
    XANMOD_APT_BASE="$fetched_base"

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
        record_apt_metapkg_state "$ch" "$pkg" "$repo_txt" "APT 源暂未收录 ${pkg}"
        if [ -n "${CH_ONLINE_VER[$ch]}" ]; then
            found_any=1
        fi
    done

    if [ "$found_any" -eq 0 ]; then
        return 1
    fi
    resolve_all_unmanaged_channels "$installed_imgs"
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
            CH_TARGET_KERNEL[$ch]=""
            continue
        fi
    done

    resolve_all_unmanaged_channels "$installed_imgs"
    return 0
}

print_installed_xanmod_summary() {
    local found_any=0
    echo -e "  ${C_DIM}已装 XanMod 内核:${C_RESET}"
    local line status pkg ver
    while IFS=$'\t' read -r status pkg ver; do
        [ -n "$pkg" ] || continue
        if [[ "$status" == ii* || "$status" == hi* ]]; then
            found_any=1
            local krel="${pkg#linux-image-}"
            local tag_run=""
            if [ "$krel" = "$CURRENT_KERNEL" ]; then
                tag_run=" ${C_BGREEN}[运行中]${C_RESET}"
            fi
            echo -e "  ${C_GREEN}•${C_RESET} ${C_BWHITE}${krel}${C_RESET}${tag_run}"
        fi
    done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' 'linux-image-*xanmod*' 2>/dev/null || true)

    if [ "$found_any" -eq 0 ]; then
        echo -e "  ${C_DIM}无${C_RESET}"
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

    info "正在配置 ${label} APT 源..."
    if ! http_get "$key_url" "$key_tmp" 30 1; then
        err "下载 GPG 密钥失败: $key_url"
        return 1
    fi

    if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$key_tmp" 2>/dev/null; then
        err "GPG 公钥格式无效: $key_url"
        return 1
    fi

    install -d -m 0755 /etc/apt/keyrings
    if ! dearmor_pgp_key "$key_tmp" "$keyring"; then
        err "导入 GPG 密钥失败"
        return 1
    fi
    chmod 0644 "$keyring"
    printf '%s\n' "$source_line" > "$source_file"

    if ! apt-get update </dev/null; then
        err "apt-get update 失败，请检查软件源"
        return 1
    fi
    return 0
}

setup_amd64_apt_repo() {
    setup_apt_repo \
        "XanMod 官方" \
        "https://dl.xanmod.org/archive.key" \
        "$XANMOD_KEYRING" \
        "deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_APT_BASE} ${OS_CODENAME} main" \
        "$XANMOD_SOURCE_LIST"
}

setup_arm64_apt_repo() {
    setup_apt_repo \
        "XanMod ARM64" \
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

    echo ""
    hr_thin
    echo -e "  ${C_DIM}通道:${C_RESET} ${C_BCYAN}${ch^^}${C_RESET}"
    echo -e "  ${C_DIM}元包:${C_RESET} ${C_BWHITE}${pkg}${C_RESET}"
    echo -e "  ${C_DIM}版本:${C_RESET} ${C_BGREEN}${online_ver}${C_RESET}"
    [ -n "$target_k" ] && echo -e "  ${C_DIM}内核:${C_RESET} ${C_BGREEN}${target_k}${C_RESET}"

    local do_apt_install=1
    if [ -n "$meta_installed" ] && [ "$meta_installed" = "$online_ver" ]; then
        if [ -n "$target_k" ] && [ "$CURRENT_KERNEL" = "$target_k" ]; then
            echo ""
            ok "该通道已是最新版本并运行中"
            if ! prompt_binary_menu "重配 GRUB 启动项" "取消返回"; then
                return 0
            fi
            do_apt_install=0
        else
            echo ""
            warn "该通道已安装最新版本，当前运行 ${CURRENT_KERNEL}"
            if ! prompt_binary_menu "设为默认启动并重启" "取消返回"; then
                return 0
            fi
            do_apt_install=0
        fi
    else
        [ -n "$meta_installed" ] && echo -e "  ${C_DIM}当前:${C_RESET} ${C_YELLOW}${meta_installed}${C_RESET}"
        if [ -z "$meta_installed" ] && [ -n "$installed_ver" ]; then
            echo -e "  ${C_DIM}当前:${C_RESET} ${C_YELLOW}${installed_ver}${C_RESET}"
        fi
        if ! prompt_binary_menu "确认安装" "取消返回"; then
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
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" </dev/null; then
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
        err "未能确定新安装的 XanMod 内核版本号"
        return 1
    fi

    configure_grub_for_kernel "$target_k" || return 1
    INSTALL_CHANGED=1
    prompt_enter_reboot "XanMod ${ch^^} 安装完成"
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

    echo ""
    hr_thin
    echo -e "  ${C_DIM}通道:${C_RESET} ${C_BCYAN}${ch^^}${C_RESET}"
    echo -e "  ${C_DIM}版本:${C_RESET} ${C_BGREEN}${tag}${C_RESET}"
    echo -e "  ${C_DIM}内核:${C_RESET} ${C_BGREEN}${target_k}${C_RESET}"

    local do_deb_install=1
    if [ -n "$installed_ver" ] && [ "$installed_ver" = "$target_k" ]; then
        echo ""
        if [ "$CURRENT_KERNEL" = "$target_k" ]; then
            ok "该内核已安装并运行中"
            echo -e "  ${C_BOLD}1.${C_RESET} 重配 GRUB 启动项"
        else
            warn "该内核已安装但当前运行 ${CURRENT_KERNEL}"
            echo -e "  ${C_BOLD}1.${C_RESET} 设为默认启动并重启"
        fi
        echo -e "  ${C_BOLD}2.${C_RESET} 重新下载并重装"
        echo -e "  ${C_BOLD}0.${C_RESET} 取消返回"
        local act=""
        while true; do
            read_input act "  请选择: " || return 0
            case "$act" in
                "") continue ;;
                1)  do_deb_install=0; break ;;
                2)  do_deb_install=1; break ;;
                0)  return 0 ;;
                *)  warn "无效选项: ${act}" ;;
            esac
        done
    else
        echo -e "  ${C_DIM}镜像:${C_RESET} ${CH_IMG_NAME[$ch]}"
        echo -e "  ${C_DIM}头包:${C_RESET} ${CH_HDR_NAME[$ch]}"
        if ! prompt_binary_menu "确认下载并安装" "取消返回"; then
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
            info "正在校验 SHA256SUMS ..."
            if ! http_get "${CH_SUM_URL[$ch]}" "$sum_file" 60 1; then
                err "下载 SHA256SUMS 失败"
                return 1
            fi
            if ! grep -Fq "${CH_IMG_NAME[$ch]}" "$sum_file" || ! grep -Fq "${CH_HDR_NAME[$ch]}" "$sum_file"; then
                err "SHA256SUMS 缺少目标包校验条目"
                return 1
            fi
            if ! (cd "$dl_dir" && sha256sum -c --ignore-missing SHA256SUMS); then
                err "SHA256 校验失败"
                return 1
            fi
            ok "SHA256 校验通过"
        else
            warn "该 Release 无 SHA256SUMS，跳过校验"
        fi

        chmod 0644 "$img_file" "$hdr_file"
        local pkg_img_name=""
        pkg_img_name=$(dpkg-deb -f "$img_file" Package 2>/dev/null || true)
        if [[ "$pkg_img_name" == linux-image-* ]]; then
            target_k="${pkg_img_name#linux-image-}"
        fi

        echo ""
        info "正在安装 ${target_k} ..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$img_file" "$hdr_file" </dev/null; then
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
    INSTALL_CHANGED=1
    prompt_enter_reboot "XanMod ARM64 ${ch^^} 安装完成"
}

install_xanmod_menu() {
    probe_cpu_isa 0

    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
        echo ""
        err "当前架构 ${ARCH} 暂不支持自动安装"
        pause_continue "按回车返回..."
        return 1
    fi

    check_runtime_tools || { pause_continue "按回车返回..."; return 1; }

    local need_refresh=1
    while true; do
        if [ "$need_refresh" -eq 1 ]; then
            echo ""
            reset_channel_cache
            if [ "$ARCH" = "amd64" ]; then
                fetch_amd64_channels || { pause_continue "按回车返回主菜单..."; return 1; }
            else
                fetch_arm64_channels || { pause_continue "按回车返回主菜单..."; return 1; }
            fi
            need_refresh=0
        fi

        print_banner
        print_system_summary
        print_installed_xanmod_summary
        hr_thin
        echo -e "  ${C_BWHITE}选择安装通道:${C_RESET}"
        echo ""

        local idx=1 ch
        for ch in "${CHANNELS[@]}"; do
            local color online_v inst_v target_k reason short_v badge=""
            color=$(channel_color "$ch")
            online_v="${CH_ONLINE_VER[$ch]}"
            inst_v="${CH_INSTALLED_VER[$ch]}"
            target_k="${CH_TARGET_KERNEL[$ch]}"
            reason="${CH_UNAVAIL_REASON[$ch]}"

            if [ -n "$reason" ] || [ -z "$online_v" ]; then
                badge="${C_RED}[不可用]${C_RESET}"
                printf "  ${C_BOLD}%d.${C_RESET} ${color}%-4s${C_RESET} %b\n" "$idx" "${ch^^}" "$badge"
            else
                short_v=$(short_ver_display "$online_v")
                local meta_inst="${CH_META_INSTALLED[$ch]}"
                if [ -n "$inst_v" ] && { [ "$inst_v" = "$online_v" ] || [ "$inst_v" = "$target_k" ]; }; then
                    if [ "$ARCH" = "arm64" ] && [ "$ARM64_USE_APT" -eq 1 ] && [ -z "$meta_inst" ]; then
                        badge="${C_BYELLOW}[未纳管]${C_RESET}"
                    elif [ -n "$target_k" ] && [ "$CURRENT_KERNEL" = "$target_k" ]; then
                        badge="${C_BGREEN}[运行中]${C_RESET}"
                    else
                        badge="${C_BCYAN}[待重启]${C_RESET}"
                    fi
                elif [ -n "$inst_v" ]; then
                    if [ -n "$meta_inst" ] && dpkg --compare-versions "$inst_v" ge "$online_v" 2>/dev/null; then
                        if [ -n "$target_k" ] && [ "$CURRENT_KERNEL" = "$target_k" ]; then
                            badge="${C_BGREEN}[运行中]${C_RESET}"
                        else
                            badge="${C_BCYAN}[已安装]${C_RESET}"
                        fi
                    else
                        badge="${C_BYELLOW}[可升级]${C_RESET}"
                    fi
                else
                    badge="${C_DIM}[未安装]${C_RESET}"
                fi
                printf "  ${C_BOLD}%d.${C_RESET} ${color}%-4s${C_RESET} ${C_BWHITE}%s${C_RESET} %b\n" "$idx" "${ch^^}" "$short_v" "$badge"
            fi
            idx=$((idx + 1))
        done

        echo -e "  ${C_BOLD}4.${C_RESET} ${C_CYAN}刷新版本${C_RESET}"
        echo -e "  ${C_BOLD}0.${C_RESET} ${C_DIM}返回主菜单${C_RESET}"
        hr_thin

        local choice=""
        while true; do
            read_input choice "  请选择: " || return 0
            case "$choice" in
                "")
                    continue
                    ;;
                1|2|3)
                    local selected_ch="${CHANNELS[$((choice - 1))]}"
                    if [ -n "${CH_UNAVAIL_REASON[$selected_ch]}" ] || [ -z "${CH_ONLINE_VER[$selected_ch]}" ]; then
                        warn "通道 ${selected_ch^^} 不可用: ${CH_UNAVAIL_REASON[$selected_ch]:-未获取版本}"
                        continue
                    fi
                    INSTALL_CHANGED=0
                    if [ "$ARCH" = "amd64" ]; then
                        install_amd64_channel "$selected_ch" || pause_continue "按回车继续..."
                    else
                        install_arm64_channel "$selected_ch" || pause_continue "按回车继续..."
                    fi
                    [ "$INSTALL_CHANGED" -eq 1 ] && need_refresh=1
                    break
                    ;;
                4)
                    need_refresh=1
                    break
                    ;;
                0)
                    return 0
                    ;;
                *)
                    warn "无效选项: ${choice}"
                    ;;
            esac
        done
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
            local img_krel=""
            img_krel=$(extract_pkg_krel "$pkg")
            [ -n "$img_krel" ] && installed_image_set[$img_krel]=1
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
    INACTIVE_STATUSES=()
    UNMANAGED_NEWER_KERNELS=()
    UNMANAGED_OTHER_KERNELS=()

    for pkg in $(printf '%s\n' "${!pkg_status[@]}" | sort -V); do
        st="${pkg_status[$pkg]}"
        ver="${pkg_ver[$pkg]}"
        deps="${pkg_deps[$pkg]}"

        if is_versioned_kernel_pkg "$pkg"; then
            if [ -n "${protected_set[$pkg]:-}" ]; then
                PROTECTED_RECORDS+=("内核"$'\t'"${pkg}"$'\t'"${ver}")
                continue
            fi

            if [[ "$st" == rc* ]]; then
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("残留")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("残留配置")
                INACTIVE_CLASSES+=("older")
                INACTIVE_STATUSES+=("rc")
            elif [[ "$st" == ii* || "$st" == hi* ]]; then
                local pkg_cmp cand_flavor rel_class note grub_hint=""
                pkg_cmp=$(get_pkg_cmp_version "$pkg" "$ver")
                cand_flavor=$(extract_pkg_flavor "$pkg")
                rel_class=$(compare_kernel_vs_running "$pkg_cmp" "$cur_cmp_ver" "$cand_flavor" "$cur_flavor")

                local pkg_krel=""
                pkg_krel=$(extract_pkg_krel "$pkg")
                if [ -n "$pkg_krel" ] && [ -n "$GRUB_PENDING_KERNEL" ] && [ "$pkg_krel" = "$GRUB_PENDING_KERNEL" ]; then
                    grub_hint="·默认启动"
                fi

                case "$rel_class" in
                    newer) note="待重启新内核${grub_hint}" ;;
                    older) note="旧内核${grub_hint}" ;;
                    *)     note="同系分支${grub_hint}" ;;
                esac
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("内核")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("$note")
                INACTIVE_CLASSES+=("$rel_class")
                INACTIVE_STATUSES+=("${st:0:2}")
            fi
        elif is_kernel_metapkg "$pkg" "$deps"; then
            if [ -n "${protected_set[$pkg]:-}" ]; then
                PROTECTED_RECORDS+=("元包"$'\t'"${pkg}"$'\t'"${ver}")
                continue
            fi

            if [[ "$st" == rc* ]]; then
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("残留")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("元包残留")
                INACTIVE_CLASSES+=("older")
                INACTIVE_STATUSES+=("rc")
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
                    newer) note="待重启元包" ;;
                    older) note="旧元包" ;;
                    *)     note="同系元包" ;;
                esac
                INACTIVE_PKGS+=("$pkg")
                INACTIVE_TYPES+=("元包")
                INACTIVE_VERS+=("$ver")
                INACTIVE_NOTES+=("$note")
                INACTIVE_CLASSES+=("$rel_class")
                INACTIVE_STATUSES+=("${st:0:2}")
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

list_apt_kernel_cache_files() {
    local d
    for d in /var/cache/apt/archives /var/cache/apt/archives/partial; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f \( \
            -name 'linux-image-*.deb*' -o \
            -name 'linux-headers-*.deb*' -o \
            -name 'linux-modules-*.deb*' -o \
            -name 'linux-tools-*.deb*' -o \
            -name 'linux-cloud-tools-*.deb*' -o \
            -name 'linux-buildinfo-*.deb*' -o \
            -name 'linux-kbuild-*.deb*' -o \
            -name 'linux-libc-dev*.deb*' -o \
            -name 'linux-xanmod*.deb*' -o \
            -name 'linux-generic*.deb*' -o \
            -name 'linux-lowlatency*.deb*' -o \
            -name 'linux-virtual*.deb*' -o \
            -name 'linux-oem*.deb*' -o \
            -name 'proxmox-kernel*.deb*' -o \
            -name 'proxmox-headers*.deb*' -o \
            -name 'pve-kernel*.deb*' -o \
            -name 'pve-headers*.deb*' \
        \) 2>/dev/null || true
    done
}

get_apt_kernel_cache_bytes() {
    local -a files=()
    mapfile -t files < <(list_apt_kernel_cache_files)
    if [ "${#files[@]}" -eq 0 ]; then
        echo "0"
        return 0
    fi
    stat -c '%s' "${files[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%.0f\n", s+0}'
}

format_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB", b/1073741824;
        else if (b >= 1048576) printf "%.1f MB", b/1048576;
        else if (b >= 1024) printf "%.0f KB", b/1024;
        else printf "%d B", b;
    }'
}

clear_apt_kernel_cache() {
    local before_bytes=0
    local -a cache_files=()
    mapfile -t cache_files < <(list_apt_kernel_cache_files)
    if [ "${#cache_files[@]}" -gt 0 ]; then
        before_bytes=$(stat -c '%s' "${cache_files[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%.0f\n", s+0}')
        rm -f "${cache_files[@]}"
    fi
    rm -rf /tmp/xanmod-arm64 /tmp/xanmod-* 2>/dev/null || true
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get autoclean </dev/null >/dev/null 2>&1 || true
    fi
    if [ "$before_bytes" -gt 0 ]; then
        ok "已清理 APT 内核缓存: $(format_bytes "$before_bytes")"
    else
        info "APT 无残留内核缓存"
    fi
}

cleanup_orphaned_kernel_artifacts() {
    local krel=""
    for krel in "$@"; do
        [ -n "$krel" ] || continue
        [ "$krel" = "$CURRENT_KERNEL" ] && continue
        local still_inst=0 cand="" st=""
        for cand in "linux-image-${krel}" "linux-image-unsigned-${krel}" "proxmox-kernel-${krel}" "pve-kernel-${krel}"; do
            st=$(dpkg-query -W -f='${db:Status-Abbrev}\n' "$cand" 2>/dev/null || true)
            if [[ "$st" == ii* || "$st" == hi* ]]; then
                still_inst=1
                break
            fi
        done
        if [ "$still_inst" -eq 0 ]; then
            [ -d "/lib/modules/${krel}" ] && rm -rf "/lib/modules/${krel}"
            rm -f "/boot/initrd.img-${krel}.bak"
        fi
    done
}

select_manual_cleanup_indices() {
    local -n _out_sel="$1"
    local total="${#INACTIVE_PKGS[@]}"

    echo ""
    hr_thin
    echo -e "  ${C_BWHITE}选择要卸载的软件包:${C_RESET}"
    echo ""
    local i
    for ((i = 0; i < total; i++)); do
        local num=$((i + 1))
        local p_name="${INACTIVE_PKGS[$i]}"
        local p_note="${INACTIVE_NOTES[$i]}"
        local p_class="${INACTIVE_CLASSES[$i]}"
        local nc="$C_BYELLOW"
        [ "$p_class" = "newer" ] && nc="$C_BCYAN"
        [ "$p_class" = "same" ] && nc="$C_MAGENTA"
        printf "  ${C_BOLD}%d.${C_RESET} ${C_BWHITE}%s${C_RESET}\n" "$num" "$p_name"
        echo -e "     ${nc}${p_note}${C_RESET}"
    done
    echo -e "  ${C_BOLD}0.${C_RESET} ${C_DIM}取消返回${C_RESET}"
    hr_thin

    local sel=""
    while true; do
        read_input sel "  输入编号，空格分隔，0 返回: " || return 1
        case "$sel" in
            "")
                continue
                ;;
            0)
                return 1
                ;;
            *)
                if mapfile -t _out_sel < <(parse_index_selection "$sel" "$total"); then
                    return 0
                fi
                warn "编号无效: ${sel}"
                ;;
        esac
    done
}

purge_selected_kernels() {
    local -a selected_indices=("$@")
    local -a apt_pkgs=() rc_pkgs=() unhold_pkgs=() purged_krels=() newer_selected=()
    local -A prot_map=() krel_seen=()
    local p s_idx arr_i st krel

    for p in "${CLEANUP_PROTECTED_PKGS[@]}"; do
        prot_map[$p]=1
    done

    echo ""
    echo -e "  ${C_BRED}即将卸载以下 ${#selected_indices[@]} 项:${C_RESET}"
    for s_idx in "${selected_indices[@]}"; do
        arr_i=$((s_idx - 1))
        p="${INACTIVE_PKGS[$arr_i]}"
        st="${INACTIVE_STATUSES[$arr_i]}"
        if [ -n "${prot_map[$p]:-}" ]; then
            err "已拦截受保护包: ${p}"
            return 1
        fi
        if [ "$st" = "rc" ]; then
            rc_pkgs+=("$p")
        else
            apt_pkgs+=("$p")
            [ "$st" = "hi" ] && unhold_pkgs+=("$p")
        fi
        krel=$(extract_pkg_krel "$p")
        if [ -n "$krel" ] && [ -z "${krel_seen[$krel]:-}" ]; then
            krel_seen[$krel]=1
            purged_krels+=("$krel")
        fi
        if [ "${INACTIVE_CLASSES[$arr_i]}" = "newer" ]; then
            newer_selected+=("$p")
        fi
        echo -e "  ${C_RED}✖${C_RESET} ${C_BWHITE}${p}${C_RESET}"
    done

    if [ "${#newer_selected[@]}" -gt 0 ]; then
        echo ""
        warn "包含未重启的新版内核，卸载后无法切入新内核"
    fi

    if ! prompt_binary_menu "确认卸载并清缓存" "取消返回"; then
        return 0
    fi

    echo ""
    if [ "${#unhold_pkgs[@]}" -gt 0 ]; then
        info "正在解除内核包锁定..."
        apt-mark unhold "${unhold_pkgs[@]}" </dev/null >/dev/null 2>&1 || true
    fi

    if [ "${#apt_pkgs[@]}" -gt 0 ]; then
        info "正在卸载旧内核包..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            "${apt_pkgs[@]}" </dev/null; then
            err "apt-get purge 执行失败"
            return 1
        fi
        local leftover_rc="" p_st p_nm
        while IFS=$'\t' read -r p_st p_nm; do
            [ -n "$p_nm" ] || continue
            [[ "$p_st" == rc* ]] && rc_pkgs+=("$p_nm")
        done < <(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' "${apt_pkgs[@]}" 2>/dev/null || true)
    fi

    if [ "${#rc_pkgs[@]}" -gt 0 ]; then
        info "正在清理残留配置..."
        DEBIAN_FRONTEND=noninteractive dpkg --purge "${rc_pkgs[@]}" </dev/null || warn "部分残留配置清理异常"
    fi

    if [ "${#apt_pkgs[@]}" -gt 0 ]; then
        info "正在执行 autoremove..."
        DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y </dev/null || warn "autoremove 返回异常"
    fi

    if [ "${#purged_krels[@]}" -gt 0 ]; then
        cleanup_orphaned_kernel_artifacts "${purged_krels[@]}"
    fi

    clear_apt_kernel_cache

    if command -v update-grub >/dev/null 2>&1 && [ -d /boot/grub ]; then
        info "正在更新 GRUB 配置..."
        if update-grub </dev/null; then
            if [ -f /boot/grub/grub.cfg ] && [ -f /boot/grub/grubenv ]; then
                local saved_entry=""
                saved_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
                if [ -n "$saved_entry" ] && [[ "$saved_entry" != [0-9]* ]]; then
                    local leaf_id="${saved_entry##*>}"
                    if ! grep -Fq -- "$leaf_id" /boot/grub/grub.cfg; then
                        warn "原默认启动项已移除，重置为 ${CURRENT_KERNEL}"
                        configure_grub_for_kernel "$CURRENT_KERNEL" || warn "更新 GRUB 默认项失败"
                    fi
                fi
            fi
        else
            warn "update-grub 执行失败，请检查 GRUB"
        fi
    fi

    prompt_enter_reboot "旧内核与缓存清理完成"
    return 0
}

cleanup_old_kernels_menu() {
    while true; do
        local -a PROTECTED_RECORDS=() CLEANUP_PROTECTED_PKGS=()
        local -a INACTIVE_PKGS=() INACTIVE_TYPES=() INACTIVE_VERS=() INACTIVE_NOTES=() INACTIVE_CLASSES=() INACTIVE_STATUSES=()
        local -a UNMANAGED_NEWER_KERNELS=() UNMANAGED_OTHER_KERNELS=()
        local CUR_CMP_VER_DISPLAY="" GRUB_PENDING_KERNEL=""

        scan_installed_kernels

        local total="${#INACTIVE_PKGS[@]}"
        local old_count=0 newer_count=0 same_count=0 i
        for ((i = 0; i < total; i++)); do
            case "${INACTIVE_CLASSES[$i]}" in
                older) old_count=$((old_count + 1)) ;;
                newer) newer_count=$((newer_count + 1)) ;;
                *)     same_count=$((same_count + 1)) ;;
            esac
        done

        local cache_bytes=0
        cache_bytes=$(get_apt_kernel_cache_bytes)

        print_banner
        print_system_summary

        echo -e "  ${C_BGREEN}受保护内核:${C_RESET}"
        if [ "${#PROTECTED_RECORDS[@]}" -eq 0 ]; then
            echo -e "  ${C_YELLOW}•${C_RESET} ${CURRENT_KERNEL}"
        else
            local rec r_type r_pkg r_ver
            for rec in "${PROTECTED_RECORDS[@]}"; do
                IFS=$'\t' read -r r_type r_pkg r_ver <<< "$rec"
                echo -e "  ${C_GREEN}•${C_RESET} ${C_BWHITE}${r_pkg}${C_RESET}"
            done
        fi

        if [ "$newer_count" -gt 0 ] || [ "${#UNMANAGED_NEWER_KERNELS[@]}" -gt 0 ]; then
            echo ""
            echo -e "  ${C_BCYAN}待重启新内核:${C_RESET}"
            for ((i = 0; i < total; i++)); do
                if [ "${INACTIVE_CLASSES[$i]}" = "newer" ] && [[ "${INACTIVE_PKGS[$i]}" =~ ^(linux-image|proxmox-kernel|pve-kernel) ]]; then
                    echo -e "  ${C_BCYAN}•${C_RESET} ${C_BWHITE}${INACTIVE_PKGS[$i]}${C_RESET}"
                fi
            done
            local uk
            for uk in "${UNMANAGED_NEWER_KERNELS[@]}"; do
                echo -e "  ${C_BCYAN}•${C_RESET} /lib/modules/${uk}"
            done
        fi

        if [ "$old_count" -gt 0 ]; then
            echo ""
            echo -e "  ${C_BYELLOW}可清理旧内核:${C_RESET}"
            for ((i = 0; i < total; i++)); do
                if [ "${INACTIVE_CLASSES[$i]}" = "older" ]; then
                    local suffix=""
                    [ "${INACTIVE_STATUSES[$i]}" = "rc" ] && suffix=" ${C_DIM}[残留]${C_RESET}"
                    echo -e "  ${C_YELLOW}•${C_RESET} ${C_BWHITE}${INACTIVE_PKGS[$i]}${C_RESET}${suffix}"
                fi
            done
        fi

        if [ "$same_count" -gt 0 ]; then
            echo ""
            echo -e "  ${C_MAGENTA}同系其它分支:${C_RESET}"
            for ((i = 0; i < total; i++)); do
                if [ "${INACTIVE_CLASSES[$i]}" != "older" ] && [ "${INACTIVE_CLASSES[$i]}" != "newer" ]; then
                    echo -e "  ${C_MAGENTA}•${C_RESET} ${C_BWHITE}${INACTIVE_PKGS[$i]}${C_RESET}"
                fi
            done
        fi

        if [ "${#UNMANAGED_OTHER_KERNELS[@]}" -gt 0 ]; then
            echo ""
            echo -e "  ${C_DIM}手动编译模块: ${UNMANAGED_OTHER_KERNELS[*]}${C_RESET}"
        fi

        echo ""
        echo -e "  ${C_DIM}APT 内核缓存:${C_RESET} ${C_CYAN}$(format_bytes "$cache_bytes")${C_RESET}"
        hr_thin

        if [ "$total" -eq 0 ] && [ "$cache_bytes" -eq 0 ]; then
            ok "无需清理的旧内核或缓存"
            if prompt_binary_menu "刷新检测" "返回主菜单"; then
                continue
            fi
            return 0
        fi

        local -a act_keys=() act_labels=()
        if [ "$old_count" -gt 0 ]; then
            act_keys+=("old")
            act_labels+=("${C_BGREEN}清理全部旧内核 · ${old_count} 项${C_RESET}")
        fi
        if [ "$newer_count" -gt 0 ]; then
            act_keys+=("reboot")
            act_labels+=("${C_BCYAN}立即重启切换新内核${C_RESET}")
        fi
        if [ "$newer_count" -gt 0 ] || [ "$same_count" -gt 0 ]; then
            act_keys+=("all")
            act_labels+=("${C_BRED}清理全部未启用 · ${total} 项${C_RESET}")
        fi
        if [ "$total" -gt 0 ]; then
            act_keys+=("pick")
            act_labels+=("按编号选择卸载")
        fi
        if [ "$cache_bytes" -gt 0 ]; then
            act_keys+=("cache")
            act_labels+=("${C_CYAN}仅清 APT 内核缓存${C_RESET}")
        fi

        local opt_count="${#act_keys[@]}"
        for ((i = 0; i < opt_count; i++)); do
            echo -e "  ${C_BOLD}$((i + 1)).${C_RESET} ${act_labels[$i]}"
        done
        echo -e "  ${C_BOLD}0.${C_RESET} ${C_DIM}返回主菜单${C_RESET}"
        hr_thin

        local sel="" chosen_key=""
        while true; do
            read_input sel "  请选择: " || return 0
            case "$sel" in
                "")
                    continue
                    ;;
                0)
                    return 0
                    ;;
                *)
                    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$opt_count" ]; then
                        chosen_key="${act_keys[$((sel - 1))]}"
                        break
                    fi
                    warn "无效选项: ${sel}"
                    ;;
            esac
        done

        local -a selected_indices=()
        case "$chosen_key" in
            reboot)
                prompt_enter_reboot "准备重启切换至新内核"
                return 0
                ;;
            cache)
                clear_apt_kernel_cache
                ;;
            old)
                for ((i = 0; i < total; i++)); do
                    [ "${INACTIVE_CLASSES[$i]}" = "older" ] && selected_indices+=("$((i + 1))")
                done
                purge_selected_kernels "${selected_indices[@]}" || pause_continue "按回车继续..."
                ;;
            all)
                for ((i = 0; i < total; i++)); do
                    selected_indices+=("$((i + 1))")
                done
                purge_selected_kernels "${selected_indices[@]}" || pause_continue "按回车继续..."
                ;;
            pick)
                if select_manual_cleanup_indices selected_indices; then
                    purge_selected_kernels "${selected_indices[@]}" || pause_continue "按回车继续..."
                fi
                ;;
        esac
    done
}

main_menu() {
    local first_prompt=1
    while true; do
        print_banner
        print_system_summary
        echo -e "  ${C_BOLD}1.${C_RESET} ${C_BGREEN}安装 XanMod 内核${C_RESET}"
        echo -e "  ${C_BOLD}2.${C_RESET} ${C_BYELLOW}清理旧内核${C_RESET}"
        echo -e "  ${C_BOLD}3.${C_RESET} ${C_DIM}退出${C_RESET}"
        hr

        if [ "$first_prompt" -eq 1 ]; then
            flush_tty_input
            first_prompt=0
        fi

        local opt=""
        while true; do
            read_input opt "  请选择: " || return 0
            case "$opt" in
                "")
                    continue
                    ;;
                1)
                    install_xanmod_menu
                    break
                    ;;
                2)
                    cleanup_old_kernels_menu
                    break
                    ;;
                3|0)
                    echo ""
                    info "已退出。"
                    exit 0
                    ;;
                *)
                    warn "无效选项: ${opt}"
                    ;;
            esac
        done
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
