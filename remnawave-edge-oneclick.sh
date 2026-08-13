#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

# Remnawave Panel 2.8.1 / Node 2.8.0 one-file edge wizard.
#
# Data plane:
#   TCP/443 -> HAProxy SNI router -> RAW+REALITY or Caddy -> XHTTP packet-up
#   UDP/443 -> optional Hysteria2
#
# RAW uses a real local HTTPS site as REALITY's self-steal target.  Client Hosts
# default to the Firefox uTLS fingerprint.  An optional second RAW Host applies
# client-side ClientHello fragmentation; FinalMask is deliberately never placed
# on a REALITY server inbound because Xray 26.6.27 has a known crash regression
# in that combination.  The script never edits Panel directly: SECRET_KEY and
# Host UUIDs are Panel outputs and are requested only at explicit stage gates.

SCRIPT_VERSION='2026-08-13.4'
EXPECTED_XRAY_VERSION='26.6.27'
NODE_IMAGE='remnawave/node@sha256:03f14935751b4ab565181e2b1766ccd1a9ac349d6839acd3ee49014e543fa232'
HAPROXY_IMAGE='haproxy@sha256:79799e8b2977e60802774fa53d29e6b54e045402cdd8a8b9fe43923e7095a047'
CADDY_IMAGE='caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'

INSTALL_DIR="${RW_INSTALL_DIR:-/opt/remnawave-edge}"
STATE_FILE=''
PRIVATE_DIR=''
SKIP_DNS="${RW_SKIP_DNS:-0}"
SKIP_UFW="${RW_SKIP_UFW:-0}"
NON_INTERACTIVE="${RW_NON_INTERACTIVE:-0}"
SHOW_VALUES="${RW_SHOW_VALUES:-0}"
NO_COLOR_REQUESTED="${RW_NO_COLOR:-${NO_COLOR:+1}}"
ASCII_REQUESTED="${RW_ASCII:-0}"
QUIET_UI="${RW_QUIET:-0}"

RAW_BACKEND_PORT=18443
XHTTP_BACKEND_PORT=18444
CADDY_BACKEND_PORT=19443
HAPROXY_STATS_PORT=8404
HYSTERIA_MASQ_PORT=19080
RAW_TEST_PORT=21081
XHTTP_TEST_PORT=21082
HYSTERIA_TEST_PORT=21083
RAW_FRAGMENT_TEST_PORT=21084

STAGE_UFW_SNAPSHOT=''
STAGE_TUNING_WAS_NEW=0
STAGE_STOP_NODE=0
STAGE_STOP_HAPROXY=0
STAGE_STOP_CADDY=0

UI_TTY=0
UI_COLOR=0
UI_UNICODE=0
UI_COLUMNS=80
UI_RESET=''
UI_BOLD=''
UI_DIM=''
UI_CYAN=''
UI_BLUE=''
UI_GREEN=''
UI_YELLOW=''
UI_RED=''
UI_ICON_INFO='i'
UI_ICON_OK='+'
UI_ICON_WARN='!'
UI_ICON_ERROR='x'
UI_ICON_STEP='>'

ui_init() {
    local detected_columns=''
    [[ -t 1 && "${TERM:-dumb}" != dumb ]] && UI_TTY=1
    if [[ "${UI_TTY}" == 1 ]] && command -v tput >/dev/null 2>&1; then
        detected_columns="$(tput cols 2>/dev/null || true)"
        [[ "${detected_columns}" =~ ^[0-9]+$ ]] && UI_COLUMNS="${detected_columns}"
    fi
    if [[ "${UI_TTY}" == 1 && "${NO_COLOR_REQUESTED:-0}" != 1 ]]; then
        UI_COLOR=1
        UI_RESET=$'\033[0m'
        UI_BOLD=$'\033[1m'
        UI_DIM=$'\033[2m'
        UI_CYAN=$'\033[36m'
        UI_BLUE=$'\033[34m'
        UI_GREEN=$'\033[32m'
        UI_YELLOW=$'\033[33m'
        UI_RED=$'\033[31m'
    fi
    if [[ "${UI_TTY}" == 1 && "${ASCII_REQUESTED}" != 1 && \
          "${LANG:-}${LC_CTYPE:-}" =~ [Uu][Tt][Ff]-?8 ]]; then
        UI_UNICODE=1
        UI_ICON_INFO='●'
        UI_ICON_OK='✓'
        UI_ICON_WARN='▲'
        UI_ICON_ERROR='✗'
        UI_ICON_STEP='›'
    fi
}

ui_emit() {
    local level="$1" message="$2" prefix color icon fd=1
    case "${level}" in
        info)    prefix='[+]'; color="${UI_CYAN}";   icon="${UI_ICON_INFO}" ;;
        success) prefix='[+]'; color="${UI_GREEN}";  icon="${UI_ICON_OK}" ;;
        warn)    prefix='[!]'; color="${UI_YELLOW}"; icon="${UI_ICON_WARN}"; fd=2 ;;
        error)   prefix='[ERROR]'; color="${UI_RED}"; icon="${UI_ICON_ERROR}"; fd=2 ;;
        *)       prefix='[>]'; color="${UI_BLUE}";   icon="${UI_ICON_STEP}" ;;
    esac
    if [[ "${UI_COLOR}" == 1 ]]; then
        printf '%b%s%b %s\n' "${color}${UI_BOLD}" "${icon}" "${UI_RESET}" "${message}" >&"${fd}"
    else
        printf '%s %s\n' "${prefix}" "${message}" >&"${fd}"
    fi
}

log()     { ui_emit info "$*"; }
success() { ui_emit success "$*"; }
warn()    { ui_emit warn "$*"; }
die()     { ui_emit error "$*"; exit 1; }

ui_rule() {
    local width=$((UI_COLUMNS - 2))
    [[ "${UI_TTY}" == 1 && "${QUIET_UI}" != 1 ]] || return 0
    ((width > 72)) && width=72
    ((width < 24)) && width=24
    printf '%b' "${UI_DIM}${UI_BLUE}"
    printf '%*s\n' "${width}" '' | tr ' ' '-'
    printf '%b' "${UI_RESET}"
}

show_banner() {
    [[ "${UI_TTY}" == 1 && "${QUIET_UI}" != 1 ]] || return 0
    printf '\n%b' "${UI_CYAN}${UI_BOLD}"
    if ((UI_COLUMNS < 72)); then
        printf '  REMNAWAVE EDGE WIZARD\n'
        printf '  resilient 443 edge\n'
    elif [[ "${UI_UNICODE}" == 1 ]]; then
        printf '  ╭──────────────────────────────────────────────────────────────────╮\n'
        printf '  │  REMNAWAVE EDGE WIZARD                                           │\n'
        printf '  │  resilient 443 edge · safe staged deployment                    │\n'
        printf '  ╰──────────────────────────────────────────────────────────────────╯\n'
    else
        printf '  +------------------------------------------------------------------+\n'
        printf '  |  REMNAWAVE EDGE WIZARD                                           |\n'
        printf '  |  resilient 443 edge - safe staged deployment                    |\n'
        printf '  +------------------------------------------------------------------+\n'
    fi
    if ((UI_COLUMNS < 72)); then
        printf '%b  wizard %s\n  Panel 2.8.1 | Node 2.8.0\n  Xray %s%b\n\n' \
            "${UI_DIM}" "${SCRIPT_VERSION}" "${EXPECTED_XRAY_VERSION}" "${UI_RESET}"
    else
        printf '%b  wizard %s  |  Panel 2.8.1  |  Node 2.8.0  |  Xray %s%b\n\n' \
            "${UI_DIM}" "${SCRIPT_VERSION}" "${EXPECTED_XRAY_VERSION}" "${UI_RESET}"
    fi
}

ui_section() {
    local title="$1" detail="${2:-}"
    if [[ "${UI_TTY}" == 1 && "${QUIET_UI}" != 1 ]]; then
        printf '\n%b%s%b %b%s%b\n' "${UI_BLUE}${UI_BOLD}" "${UI_ICON_STEP}" "${UI_RESET}" \
            "${UI_BOLD}" "${title}" "${UI_RESET}"
        [[ -z "${detail}" ]] || printf '  %b%s%b\n' "${UI_DIM}" "${detail}" "${UI_RESET}"
        ui_rule
    else
        ui_emit step "${title}${detail:+: ${detail}}"
    fi
}

ui_kv() {
    local key="$1" value="$2"
    if [[ "${UI_COLOR}" == 1 ]]; then
        printf '  %b%-24s%b %s\n' "${UI_DIM}" "${key}" "${UI_RESET}" "${value}"
    else
        printf '  %-24s %s\n' "${key}" "${value}"
    fi
}

ui_file() {
    local label="$1" path="$2"
    if [[ "${UI_COLOR}" == 1 ]]; then
        printf '  %b%s%b  %s\n' "${UI_GREEN}${UI_BOLD}" "${UI_ICON_OK}" "${UI_RESET}" "${label}"
        printf '     %b%s%b\n' "${UI_CYAN}" "${path}" "${UI_RESET}"
    else
        printf '  [OK] %s\n     %s\n' "${label}" "${path}"
    fi
}

ui_status_row() {
    local condition="$1" label="$2" detail="${3:-}" icon marker color
    if [[ "${condition}" == ok ]]; then
        icon="${UI_ICON_OK}"
        marker='OK'
        color="${UI_GREEN}"
    else
        icon="${UI_ICON_WARN}"
        marker='CHECK'
        color="${UI_YELLOW}"
    fi
    if [[ "${UI_COLOR}" == 1 ]]; then
        printf '  %b%s%b  %-34s %s\n' "${color}${UI_BOLD}" "${icon}" "${UI_RESET}" \
            "${label}" "${detail}"
    else
        printf '  [%-5s] %-34s %s\n' "${marker}" "${label}" "${detail}"
    fi
}

announce_stage() {
    case "$1" in
        bootstrap)     ui_section 'Bootstrap' 'base packages and pinned Docker runtime' ;;
        init)          ui_section 'Initialize' 'collect settings, generate and validate protected artifacts' ;;
        panel)         ui_section 'Panel - stage 1' 'exact Remnawave 2.8.1 fields' ;;
        node)          ui_section 'Node' 'control plane, firewall and managed Xray runtime' ;;
        template)      ui_section 'Panel - stage 2' 'physical Host UUIDs and XRAY_JSON AUTO template' ;;
        edge)          ui_section 'Edge' 'HAProxy, Caddy, certificates and public 443' ;;
        verify)        ui_section 'Verification' 'DNS, mTLS, listeners, TLS and routing' ;;
        verify-auth)   ui_section 'Authenticated tests' 'every selected transport with temporary canary credentials' ;;
        tune)          ui_section 'Network tuning' 'reversible measured server baseline' ;;
        untune)        ui_section 'Restore tuning' 'restore the recorded pre-wizard sysctl state' ;;
        status)        ui_section 'Status' 'read-only runtime overview' ;;
        rollback)      ui_section 'Rollback' 'stop wizard-managed containers and preserve recovery data' ;;
        rollback-host) ui_section 'Host rollback' 'restore wizard firewall and tuning changes' ;;
        selftest)      ui_section 'Self-test' 'isolated render and validation; no service or firewall changes' ;;
        all)           ui_section 'Guided setup' 'complete staged installation with Panel checkpoints' ;;
    esac
}

acquire_global_lock() {
    exec 9>/run/lock/remnawave-edge-oneclick.lock
    flock -n 9 || die 'Another remnawave-edge-oneclick process is already running.'
}

usage() {
    cat <<'USAGE'
Remnawave Edge Wizard - Panel 2.8.1 / Node 2.8.0

Usage:
  sudo ./remnawave-edge-oneclick.sh <command>

Guided setup:
  all          Complete interactive setup with safe Panel checkpoints.
  bootstrap    Install Ubuntu/Debian packages and Docker Compose.
  init         Collect settings; generate and validate protected artifacts.
  panel        Show exact Config Profile / Node fields for Panel 2.8.1.
  node         Save Panel SECRET_KEY, apply narrow firewall rules, start Node.
  template     Collect Host UUIDs and render the XRAY_JSON AUTO template.
  edge         Start HAProxy + Caddy, obtain certificates and verify public 443.

Verification and operation:
  verify       DNS, mTLS, listener, TLS, cover-site and route checks.
  verify-auth  End-to-end test every selected transport with a canary user.
  status       Read-only runtime overview.
  selftest     Isolated render/validation; never changes services or firewall.
  tune         Apply the generated reversible network baseline.
  untune       Restore the exact sysctl values recorded before tuning.

Recovery:
  rollback       Stop only wizard containers; preserve files/firewall/DNS.
  rollback-host  Also restore wizard UFW and tuning changes; explicit confirmation.

Optional environment variables:
  RW_INSTALL_DIR, RW_NODE_NAME, RW_REALITY_SNI, RW_XHTTP_SNI, RW_EDGE_IPV4,
  RW_PANEL_IPV4, RW_ACME_EMAIL, RW_NODE_PORT, RW_NODE_SECRET_KEY,
  RW_ENABLE_HYSTERIA=0|1, RW_ENABLE_RAW_FRAGMENT=0|1,
  RW_CLIENT_FINGERPRINT (default: firefox),
  RW_RAW_HOST_UUID, RW_RAW_FRAGMENT_HOST_UUID, RW_XHTTP_HOST_UUID,
  RW_HYSTERIA_HOST_UUID, RW_EXTRA_HOST_UUIDS=uuid5,uuid6,
  RW_BLOCK_CLIENT_QUIC=0|1, RW_APPLY_TUNING=0|1,
  RW_SKIP_DNS=1, RW_SKIP_UFW=1, RW_ENABLE_UFW=1, RW_SSH_PORT,
  RW_ACCEPT_BROAD_CONTROL=1,
  RW_CONFIRM_HOST_ROLLBACK=RESTORE,
  RW_NON_INTERACTIVE=1, RW_SHOW_VALUES=1,
  RW_NO_COLOR=1 (or NO_COLOR=1), RW_ASCII=1, RW_QUIET=1

Secrets and ready JSON are stored under INSTALL_DIR/private with mode 0600.
The `panel`/`all` stages print only field-by-field instructions and protected
file paths; they never print SECRET_KEY or the generated private keys.
USAGE
}

choose_command() {
    local choice=''
    ui_section 'Choose an action' 'nothing runs until you select a command'
    if ((UI_COLUMNS >= 72)); then
        cat <<'MENU'
   1) Guided full setup          9) Full verification
   2) Bootstrap packages       10) Authenticated transport tests
   3) Safe isolated self-test  11) Read-only status
   4) Initialize files         12) Apply network tuning
   5) Show Panel stage 1       13) Restore network tuning
   6) Start / verify Node      14) Stop wizard containers
   7) Build AUTO template      15) Restore host changes
   8) Start / verify edge

   h) Help                      0) Exit
MENU
    else
        cat <<'MENU'
   1) Guided full setup
   2) Bootstrap packages
   3) Safe isolated self-test
   4) Initialize files
   5) Show Panel stage 1
   6) Start / verify Node
   7) Build AUTO template
   8) Start / verify edge
   9) Full verification
  10) Authenticated transport tests
  11) Read-only status
  12) Apply network tuning
  13) Restore network tuning
  14) Stop wizard containers
  15) Restore host changes

   h) Help
   0) Exit
MENU
    fi
    printf '\n%b?%b Select: ' "${UI_CYAN}${UI_BOLD}" "${UI_RESET}"
    IFS= read -r choice || exit 0
    case "${choice}" in
        1) SELECTED_COMMAND='all' ;;
        2) SELECTED_COMMAND='bootstrap' ;;
        3) SELECTED_COMMAND='selftest' ;;
        4) SELECTED_COMMAND='init' ;;
        5) SELECTED_COMMAND='panel' ;;
        6) SELECTED_COMMAND='node' ;;
        7) SELECTED_COMMAND='template' ;;
        8) SELECTED_COMMAND='edge' ;;
        9) SELECTED_COMMAND='verify' ;;
        10) SELECTED_COMMAND='verify-auth' ;;
        11) SELECTED_COMMAND='status' ;;
        12) SELECTED_COMMAND='tune' ;;
        13) SELECTED_COMMAND='untune' ;;
        14) SELECTED_COMMAND='rollback' ;;
        15) SELECTED_COMMAND='rollback-host' ;;
        h|H|'?') SELECTED_COMMAND='help' ;;
        0|'') exit 0 ;;
        *) die "Unknown menu choice: ${choice}" ;;
    esac
}

set_paths() {
    [[ "${INSTALL_DIR}" == /* ]] || die 'RW_INSTALL_DIR must be an absolute path.'
    INSTALL_DIR="$(realpath -m -- "${INSTALL_DIR}")"
    [[ "${INSTALL_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'RW_INSTALL_DIR contains unsafe characters.'
    case "${INSTALL_DIR}" in
        /|/bin|/boot|/dev|/etc|/home|/opt|/proc|/root|/run|/srv|/sys|/tmp|/usr|/var)
            die "Refusing broad install directory: ${INSTALL_DIR}" ;;
    esac
    STATE_FILE="${INSTALL_DIR}/private/state.env"
    PRIVATE_DIR="${INSTALL_DIR}/private"
}

require_root() {
    [[ "$(id -u)" == 0 ]] || die 'Run this command as root (sudo).'
}

need_commands() {
    local missing=() command
    for command in bash curl dig docker flock ip jq modprobe openssl python3 realpath sed ss stat sysctl tc timeout ufw; do
        command -v "${command}" >/dev/null 2>&1 || missing+=("${command}")
    done
    docker compose version >/dev/null 2>&1 || missing+=('docker-compose-v2')
    ((${#missing[@]} == 0)) || die "Missing commands: ${missing[*]}. Run the bootstrap stage."
}

base_commands_ready() {
    local command
    for command in bash curl dig docker flock ip jq modprobe openssl python3 realpath sed ss stat sysctl tc timeout ufw; do
        command -v "${command}" >/dev/null 2>&1 || return 1
    done
    docker compose version >/dev/null 2>&1
}

validate_ipv4() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
assert isinstance(ipaddress.ip_address(sys.argv[1]), ipaddress.IPv4Address)
PY
}

validate_fqdn() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import re, sys
name = sys.argv[1]
assert len(name) <= 253
labels = name.split('.')
assert len(labels) >= 2
assert re.fullmatch(r'[a-z]{2,63}', labels[-1])
for label in labels:
    assert 1 <= len(label) <= 63
    assert re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label)
PY
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

validate_hysteria_material() {
    local cert="${PRIVATE_DIR}/hysteria-tls/server.crt"
    local key="${PRIVATE_DIR}/hysteria-tls/server.key"
    local actual_pin cert_pubkey key_pubkey
    [[ -s "${cert}" && -s "${key}" ]] || die 'Hysteria TLS files are missing.'
    [[ "$(stat -c '%a' "${cert}")" == 600 && "$(stat -c '%a' "${key}")" == 600 ]] || \
        die 'Hysteria certificate and private key must have mode 0600.'
    openssl x509 -in "${cert}" -noout -checkhost "${XHTTP_SNI}" >/dev/null || \
        die 'Hysteria certificate SAN does not match XHTTP_SNI.'
    openssl x509 -in "${cert}" -noout -checkend 2592000 >/dev/null || \
        die 'Hysteria certificate expires in less than 30 days.'
    actual_pin="$(openssl x509 -in "${cert}" -noout -fingerprint -sha256 | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
    [[ "${actual_pin}" == "${HYSTERIA_CERT_SHA256}" ]] || \
        die 'Hysteria certificate no longer matches the protected SHA-256 pin.'
    cert_pubkey="$(openssl x509 -in "${cert}" -pubkey -noout | \
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
    key_pubkey="$(openssl pkey -in "${key}" -pubout -outform DER 2>/dev/null | \
        openssl dgst -sha256)"
    [[ -n "${cert_pubkey}" && "${cert_pubkey}" == "${key_pubkey}" ]] || \
        die 'Hysteria certificate and private key do not match.'
}

prompt_value() {
    local variable="$1" label="$2" default_value="${3:-}" secret="${4:-0}"
    local current="${!variable:-}" answer=''
    if [[ -n "${current}" ]]; then return; fi
    if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then
        [[ -n "${default_value}" ]] || die "Missing required environment variable ${variable}."
        printf -v "${variable}" '%s' "${default_value}"
        return
    fi
    if [[ "${secret}" == 1 ]]; then
        printf '%b?%b %s: ' "${UI_CYAN}${UI_BOLD}" "${UI_RESET}" "${label}"
        IFS= read -r -s answer || die 'Input was interrupted.'
        printf '\n'
    elif [[ -n "${default_value}" ]]; then
        printf '%b?%b %s %b[%s]%b: ' "${UI_CYAN}${UI_BOLD}" "${UI_RESET}" "${label}" \
            "${UI_DIM}" "${default_value}" "${UI_RESET}"
        IFS= read -r answer || die 'Input was interrupted.'
        answer="${answer:-${default_value}}"
    else
        printf '%b?%b %s: ' "${UI_CYAN}${UI_BOLD}" "${UI_RESET}" "${label}"
        IFS= read -r answer || die 'Input was interrupted.'
    fi
    printf -v "${variable}" '%s' "${answer}"
}

prompt_yes_no() {
    local variable="$1" label="$2" default_value="${3:-1}" current answer suffix
    current="${!variable:-}"
    [[ -n "${current}" ]] && return 0
    if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then
        printf -v "${variable}" '%s' "${default_value}"
        return 0
    fi
    [[ "${default_value}" == 1 ]] && suffix='Y/n' || suffix='y/N'
    while true; do
        printf '%b?%b %s %b[%s]%b: ' "${UI_CYAN}${UI_BOLD}" "${UI_RESET}" "${label}" \
            "${UI_DIM}" "${suffix}" "${UI_RESET}"
        IFS= read -r answer || die 'Input was interrupted.'
        answer="${answer,,}"
        case "${answer}" in
            '') printf -v "${variable}" '%s' "${default_value}"; return 0 ;;
            y|yes) printf -v "${variable}" '%s' 1; return 0 ;;
            n|no) printf -v "${variable}" '%s' 0; return 0 ;;
            *) warn 'Please answer y or n.' ;;
        esac
    done
}

confirm_phrase() {
    local label="$1" phrase="$2" answer=''
    printf '%b!%b %s\n' "${UI_YELLOW}${UI_BOLD}" "${UI_RESET}" "${label}"
    printf '%b?%b Type %b%s%b to continue: ' "${UI_CYAN}${UI_BOLD}" "${UI_RESET}" \
        "${UI_BOLD}" "${phrase}" "${UI_RESET}"
    IFS= read -r answer || die 'Input was interrupted.'
    [[ "${answer}" == "${phrase}" ]]
}

confirm_continue() {
    local answer=''
    if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then return 0; fi
    printf '%b?%b Generate and validate this configuration? %b[Y/n]%b: ' \
        "${UI_CYAN}${UI_BOLD}" "${UI_RESET}" "${UI_DIM}" "${UI_RESET}"
    IFS= read -r answer || die 'Input was interrupted.'
    [[ "${answer,,}" != n && "${answer,,}" != no ]] || die 'Initialization cancelled; no configuration was generated.'
}

wait_for_enter() {
    local text="$1"
    if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then return; fi
    printf '\n%b%s%b\n' "${UI_YELLOW}${UI_BOLD}" "${text}" "${UI_RESET}"
    printf '%bPress Enter to continue...%b ' "${UI_DIM}" "${UI_RESET}"
    IFS= read -r _ || die 'Input was interrupted.'
}

write_state() {
    local state_tmp
    install -d -m 0700 "${PRIVATE_DIR}"
    state_tmp="$(mktemp "${PRIVATE_DIR}/.state.env.XXXXXX")"
    if ! {
        printf 'REALITY_SNI=%q\n' "${REALITY_SNI}"
        printf 'XHTTP_SNI=%q\n' "${XHTTP_SNI}"
        printf 'EDGE_IPV4=%q\n' "${EDGE_IPV4}"
        printf 'PANEL_IPV4=%q\n' "${PANEL_IPV4}"
        printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL}"
        printf 'NODE_PORT=%q\n' "${NODE_PORT}"
        printf 'NODE_SLUG=%q\n' "${NODE_SLUG}"
        printf 'NODE_CODE=%q\n' "${NODE_CODE}"
        printf 'NODE_CODE_LOWER=%q\n' "${NODE_CODE_LOWER}"
        printf 'PROFILE_NAME=%q\n' "${PROFILE_NAME}"
        printf 'RAW_TAG=%q\n' "${RAW_TAG}"
        printf 'XHTTP_TAG=%q\n' "${XHTTP_TAG}"
        printf 'HYSTERIA_TAG=%q\n' "${HYSTERIA_TAG}"
        printf 'ENABLE_HYSTERIA=%q\n' "${ENABLE_HYSTERIA}"
        printf 'ENABLE_RAW_FRAGMENT=%q\n' "${ENABLE_RAW_FRAGMENT}"
        printf 'CLIENT_FINGERPRINT=%q\n' "${CLIENT_FINGERPRINT}"
        printf 'BLOCK_CLIENT_QUIC=%q\n' "${BLOCK_CLIENT_QUIC}"
        printf 'APPLY_TUNING=%q\n' "${APPLY_TUNING}"
        printf 'NODE_CONTAINER=%q\n' "${NODE_CONTAINER}"
        printf 'HAPROXY_CONTAINER=%q\n' "${HAPROXY_CONTAINER}"
        printf 'CADDY_CONTAINER=%q\n' "${CADDY_CONTAINER}"
        printf 'COMPOSE_PROJECT=%q\n' "${COMPOSE_PROJECT}"
        printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY}"
        printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY}"
        printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID}"
        printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH}"
        [[ "${ENABLE_HYSTERIA}" != 1 ]] || printf 'HYSTERIA_CERT_SHA256=%q\n' "${HYSTERIA_CERT_SHA256}"
        [[ -z "${RAW_HOST_UUID:-}" ]] || printf 'RAW_HOST_UUID=%q\n' "${RAW_HOST_UUID}"
        [[ -z "${RAW_FRAGMENT_HOST_UUID:-}" ]] || printf 'RAW_FRAGMENT_HOST_UUID=%q\n' "${RAW_FRAGMENT_HOST_UUID}"
        [[ -z "${XHTTP_HOST_UUID:-}" ]] || printf 'XHTTP_HOST_UUID=%q\n' "${XHTTP_HOST_UUID}"
        [[ -z "${HYSTERIA_HOST_UUID:-}" ]] || printf 'HYSTERIA_HOST_UUID=%q\n' "${HYSTERIA_HOST_UUID}"
        [[ -z "${EXTRA_HOST_UUIDS:-}" ]] || printf 'EXTRA_HOST_UUIDS=%q\n' "${EXTRA_HOST_UUIDS}"
    } >"${state_tmp}"; then
        truncate -s 0 "${state_tmp}" 2>/dev/null || true
        find "${state_tmp}" -maxdepth 0 -delete 2>/dev/null || true
        return 1
    fi
    chmod 0600 "${state_tmp}"
    mv -f -- "${state_tmp}" "${STATE_FILE}"
}

load_state() {
    local required
    local -a missing=()
    set_paths
    [[ -f "${STATE_FILE}" && ! -L "${STATE_FILE}" ]] || die "Safe state not found: ${STATE_FILE}. Run init first."
    [[ "$(stat -c '%a' "${PRIVATE_DIR}")" == 700 ]] || die 'private directory must have mode 0700.'
    [[ "$(stat -c '%u' "${PRIVATE_DIR}")" == 0 ]] || die 'private directory must be owned by root.'
    [[ "$(stat -c '%a' "${STATE_FILE}")" == 600 ]] || die 'state.env must have mode 0600.'
    [[ "$(stat -c '%u' "${STATE_FILE}")" == 0 ]] || die 'state.env must be owned by root.'
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    for required in REALITY_SNI XHTTP_SNI EDGE_IPV4 PANEL_IPV4 ACME_EMAIL NODE_PORT \
        NODE_CODE NODE_CODE_LOWER PROFILE_NAME RAW_TAG XHTTP_TAG NODE_CONTAINER \
        HAPROXY_CONTAINER CADDY_CONTAINER COMPOSE_PROJECT REALITY_PRIVATE_KEY \
        REALITY_PUBLIC_KEY REALITY_SHORT_ID XHTTP_PATH; do
        [[ -n "${!required:-}" ]] || missing+=("${required}")
    done
    ((${#missing[@]} == 0)) || die "Incompatible state.env in ${INSTALL_DIR}; missing wizard fields: ${missing[*]}. Use the install directory that this wizard initialized."
    NODE_SLUG="${NODE_SLUG:-${NODE_CODE_LOWER:-legacy-node}}"
    ENABLE_HYSTERIA="${ENABLE_HYSTERIA:-0}"
    ENABLE_RAW_FRAGMENT="${ENABLE_RAW_FRAGMENT:-1}"
    CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT:-firefox}"
    CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT,,}"
    BLOCK_CLIENT_QUIC="${BLOCK_CLIENT_QUIC:-1}"
    APPLY_TUNING="${APPLY_TUNING:-0}"
    HYSTERIA_TAG="${HYSTERIA_TAG:-RW_${NODE_CODE}_HYSTERIA2}"
}

validate_fingerprint() {
    case "${1,,}" in
        chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) return 0 ;;
        *) return 1 ;;
    esac
}

pull_images() {
    local image xray_version
    for image in "${NODE_IMAGE}" "${HAPROXY_IMAGE}" "${CADDY_IMAGE}"; do
        if ! docker image inspect "${image}" >/dev/null 2>&1; then
            log "Pulling pinned image ${image%%@*}..."
            docker pull "${image}" >/dev/null
        fi
    done
    xray_version="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" version | awk 'NR == 1 {print $2}')"
    [[ "${xray_version}" == "${EXPECTED_XRAY_VERSION}" ]] || \
        die "Pinned Node image contains Xray ${xray_version:-unknown}; expected ${EXPECTED_XRAY_VERSION}."
}

generate_material() {
    local key_output
    key_output="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" x25519)"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "${key_output}" | sed -nE \
        's/^(PrivateKey|Private key):[[:space:]]*//p' | head -n 1)"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "${key_output}" | sed -nE \
        's/^(Password \(PublicKey\)|Password|PublicKey|Public key):[[:space:]]*//p' | head -n 1)"
    REALITY_SHORT_ID="$(openssl rand -hex 8)"
    XHTTP_PATH="/api/v1/$(openssl rand -hex 24)/"
    [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] || die 'Xray did not generate REALITY keys.'
    [[ "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die 'Invalid generated REALITY short ID.'
    [[ "${XHTTP_PATH}" =~ ^/api/v1/[0-9a-f]{48}/$ ]] || die 'Invalid generated XHTTP path.'
}

generate_hysteria_certificate() {
    local cert_dir="${PRIVATE_DIR}/hysteria-tls"
    install -d -m 0700 "${cert_dir}"
    openssl ecparam -name prime256v1 -genkey -noout -out "${cert_dir}/server.key"
    openssl req -new -x509 -sha256 -key "${cert_dir}/server.key" \
        -out "${cert_dir}/server.crt" -days 3650 \
        -subj "/CN=${XHTTP_SNI}" \
        -addext "subjectAltName=DNS:${XHTTP_SNI}" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=serverAuth'
    chmod 0600 "${cert_dir}/server.key" "${cert_dir}/server.crt"
    HYSTERIA_CERT_SHA256="$(openssl x509 -in "${cert_dir}/server.crt" \
        -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
    [[ "${HYSTERIA_CERT_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die 'Could not calculate Hysteria certificate pin.'
}

render_profile() {
    cat >"${PRIVATE_DIR}/config-profile.ready.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "dns": {
    "tag": "dns-internal",
    "queryStrategy": "UseIPv4",
    "disableCache": false,
    "enableParallelQuery": true,
    "servers": [
      {"address": "https://1.1.1.1/dns-query", "timeoutMs": 2500},
      {"address": "https://8.8.8.8/dns-query", "timeoutMs": 2500}
    ]
  },
  "inbounds": [
    {
      "tag": "${RAW_TAG}",
      "listen": "127.0.0.1",
      "port": ${RAW_BACKEND_PORT},
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:${CADDY_BACKEND_PORT}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        },
        "sockopt": {"acceptProxyProtocol": true}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
    },
    {
      "tag": "${XHTTP_TAG}",
      "listen": "127.0.0.1",
      "port": ${XHTTP_BACKEND_PORT},
      "protocol": "vless",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {"path": "${XHTTP_PATH}", "mode": "packet-up"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
    }
  ],
  "outbounds": [
    {"tag": "DIRECT", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"tag": "BLOCK", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "inboundTag": ["dns-internal"], "outboundTag": "DIRECT"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "DIRECT"}
    ]
  },
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true, "statsUserOnline": true}},
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "stats": {}
}
EOF
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        jq --rawfile cert "${PRIVATE_DIR}/hysteria-tls/server.crt" \
            --rawfile key "${PRIVATE_DIR}/hysteria-tls/server.key" \
            --arg tag "${HYSTERIA_TAG}" \
            --argjson masquerade_port "${HYSTERIA_MASQ_PORT}" '
          .inbounds += [
            {
              tag: $tag,
              listen: "0.0.0.0",
              port: 443,
              protocol: "hysteria",
              settings: {version: 2, clients: []},
              streamSettings: {
                network: "hysteria",
                security: "tls",
                tlsSettings: {
                  alpn: ["h3"],
                  certificates: [{
                    certificate: ($cert | rtrimstr("\n") | split("\n")),
                    key: ($key | rtrimstr("\n") | split("\n"))
                  }]
                },
                hysteriaSettings: {
                  version: 2,
                  udpIdleTimeout: 60,
                  masquerade: {
                    type: "proxy",
                    url: ("http://127.0.0.1:" + ($masquerade_port | tostring)),
                    rewriteHost: false,
                    insecure: false
                  }
                }
              },
              sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                routeOnly: true
              }
            }
          ]
        ' "${PRIVATE_DIR}/config-profile.ready.json" \
            >"${PRIVATE_DIR}/config-profile.ready.json.tmp"
        mv -f "${PRIVATE_DIR}/config-profile.ready.json.tmp" \
            "${PRIVATE_DIR}/config-profile.ready.json"
    fi
    chmod 0600 "${PRIVATE_DIR}/config-profile.ready.json"
}

render_edge_env() {
    {
        printf 'REALITY_SNI=%s\n' "${REALITY_SNI}"
        printf 'XHTTP_SNI=%s\n' "${XHTTP_SNI}"
        printf 'EDGE_IPV4=%s\n' "${EDGE_IPV4}"
        printf 'PANEL_IPV4=%s\n' "${PANEL_IPV4}"
        printf 'ACME_EMAIL=%s\n' "${ACME_EMAIL}"
        printf 'NODE_PORT=%s\n' "${NODE_PORT}"
        printf 'XHTTP_PATH=%s\n' "${XHTTP_PATH}"
    } >"${PRIVATE_DIR}/edge.env"
    chmod 0600 "${PRIVATE_DIR}/edge.env"
}

render_haproxy() {
    cat >"${INSTALL_DIR}/haproxy.cfg" <<'EOF'
global
    log stdout format raw local0
    maxconn 10000
    user haproxy
    group haproxy
    stats socket /run/haproxy.sock mode 600 level admin expose-fd listeners

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option dontlog-normal
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout tunnel 4h
    timeout client-fin 30s
    timeout server-fin 30s

frontend public_tcp_443
    bind 0.0.0.0:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    acl is_acme req.ssl_alpn -m sub acme-tls/1
    acl is_reality req.ssl_sni -i "${REALITY_SNI}"
    acl is_xhttp req.ssl_sni -i "${XHTTP_SNI}"
    use_backend caddy_tls if is_acme
    use_backend caddy_tls if is_xhttp
    use_backend xray_reality if is_reality
    default_backend xray_reality

backend xray_reality
    mode tcp
    option tcp-check
    server xray_local 127.0.0.1:18443 send-proxy-v2 check inter 5s fall 3 rise 2

backend caddy_tls
    mode tcp
    option tcp-check
    server caddy_local 127.0.0.1:19443 check inter 2s fall 3 rise 1

listen local_stats
    bind 127.0.0.1:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF
    chmod 0644 "${INSTALL_DIR}/haproxy.cfg"
}

render_caddy() {
    cat >"${INSTALL_DIR}/Caddyfile" <<'EOF'
{
    admin unix//run/caddy-admin.sock
    auto_https disable_redirects
    https_port 19443
    email {$ACME_EMAIL}
    servers {
        protocols h1 h2
        strict_sni_host on
        timeouts {
            read_header 10s
            idle 5m
        }
    }
}

(common_site) {
    root * /srv
    encode zstd gzip
    header {
        Content-Security-Policy "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'"
        Cross-Origin-Opener-Policy same-origin
        Cross-Origin-Resource-Policy same-origin
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
        -Server
    }
    @health path /health.txt
    header @health Cache-Control "no-store"
    handle_errors {
        rewrite * /404.html
        file_server
    }
}

# Loopback-only ordinary HTTP origin used by Hysteria2 masquerade.  It is never
# exposed by UFW and is served to unauthenticated HTTP/3 requests via Xray.
http://127.0.0.1:19080 {
    bind 127.0.0.1
    import common_site
    file_server
}

https://{$REALITY_SNI}:19443 {
    bind 127.0.0.1
    tls {
        issuer acme {
            disable_http_challenge
            alt_tlsalpn_port 19443
        }
        protocols tls1.2 tls1.3
        curves x25519mlkem768 x25519
    }
    import common_site
    @sitemap path /sitemap.xml
    header @sitemap Content-Type "application/xml; charset=utf-8"
    respond @sitemap `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://{$REALITY_SNI}/</loc></url>
  <url><loc>https://{$REALITY_SNI}/about.html</loc></url>
</urlset>` 200
    file_server
}

https://{$XHTTP_SNI}:19443 {
    bind 127.0.0.1
    tls {
        issuer acme {
            disable_http_challenge
            alt_tlsalpn_port 19443
        }
        protocols tls1.2 tls1.3
        curves x25519mlkem768 x25519
    }
    import common_site
    @sitemap path /sitemap.xml
    header @sitemap Content-Type "application/xml; charset=utf-8"
    respond @sitemap `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://{$XHTTP_SNI}/</loc></url>
  <url><loc>https://{$XHTTP_SNI}/about.html</loc></url>
</urlset>` 200
    @xhttp path {$XHTTP_PATH}*
    handle @xhttp {
        reverse_proxy h2c://127.0.0.1:18444 {
            flush_interval -1
        }
    }
    handle {
        file_server
    }
}
EOF
    chmod 0644 "${INSTALL_DIR}/Caddyfile"
}

render_site() {
    install -d -m 0755 "${INSTALL_DIR}/site"
    cat >"${INSTALL_DIR}/site/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="A small independent network availability and latency diagnostic">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/site.css">
  <title>Northstar Network Check</title>
</head>
<body>
  <header class="nav"><a class="brand" href="/">Northstar</a><nav><a href="/about.html">About</a><a href="/health.txt">Raw health</a></nav></header>
  <main>
    <section class="hero">
      <p class="eyebrow">Independent endpoint</p>
      <h1>Is this route healthy?</h1>
      <p class="lead">Run a lightweight same-origin check. Nothing is uploaded and the result stays in your browser.</p>
      <button id="run" type="button">Run network check</button>
    </section>
    <section class="panel" aria-live="polite">
      <div><span class="label">Endpoint</span><strong id="host">checking…</strong></div>
      <div><span class="label">Browser network</span><strong id="online">checking…</strong></div>
      <div><span class="label">HTTPS</span><strong id="secure">checking…</strong></div>
      <div><span class="label">Median response</span><strong id="latency">not measured</strong></div>
      <div><span class="label">Last check</span><strong id="checked">not measured</strong></div>
      <div><span class="label">Result</span><strong id="result" class="status">ready</strong></div>
    </section>
    <section class="note"><h2>What this tells you</h2><p>The test measures access to this endpoint over your current route. It does not inspect traffic, install software, or claim that every destination is reachable.</p><button id="copy" class="secondary" type="button">Copy report</button></section>
  </main>
  <footer>Northstar Network Check · <a href="/about.html">Privacy and method</a></footer>
  <script src="/diagnostics.js" defer></script>
</body>
</html>
EOF
    cat >"${INSTALL_DIR}/site/about.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/site.css"><title>About · Northstar</title></head><body><header class="nav"><a class="brand" href="/">Northstar</a></header><main><article class="note prose"><p class="eyebrow">About</p><h1>A deliberately small network check</h1><p>Northstar requests a tiny local health file several times and reports the median browser-observed response time. The page uses no third-party scripts, analytics, cookies, accounts or browser storage.</p><h2>Limits</h2><p>A successful result proves only that this hostname is reachable at that moment. A failed result can be caused by the local connection, routing, DNS, filtering, or endpoint maintenance.</p><p><a href="/">Return to the check</a></p></article></main><footer>Northstar Network Check</footer></body></html>
EOF
    cat >"${INSTALL_DIR}/site/404.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/site.css"><title>Not found · Northstar</title></head><body><main><article class="note prose"><p class="eyebrow">404</p><h1>That route is not here.</h1><p>The endpoint is online, but the requested resource does not exist.</p><p><a href="/">Return home</a></p></article></main></body></html>
EOF
    cat >"${INSTALL_DIR}/site/site.css" <<'EOF'
:root{color-scheme:light dark;--bg:#07111f;--panel:#0f2034;--line:#24415f;--text:#eaf3ff;--muted:#9bb0c7;--accent:#5ee6b0;--ink:#061811}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 85% 0,#183b5c 0,transparent 34rem),var(--bg);color:var(--text);font:16px/1.6 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.nav,main,footer{width:min(1040px,calc(100% - 40px));margin:auto}.nav{height:76px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line)}.nav nav{display:flex;gap:22px}.brand{font-weight:800;letter-spacing:.08em;text-transform:uppercase}.nav a,footer a,.note a{color:var(--text);text-decoration:none}.hero{padding:88px 0 42px;max-width:740px}.eyebrow{color:var(--accent);font-size:.78rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase}h1{font-size:clamp(2.6rem,8vw,5.4rem);line-height:.98;letter-spacing:-.045em;margin:.25em 0}.lead{font-size:1.18rem;color:var(--muted);max-width:650px}button{border:0;border-radius:999px;padding:13px 20px;background:var(--accent);color:var(--ink);font:inherit;font-weight:800;cursor:pointer}button:disabled{opacity:.55;cursor:wait}.secondary{background:transparent;color:var(--text);border:1px solid var(--line)}.panel{display:grid;grid-template-columns:repeat(3,1fr);border:1px solid var(--line);border-radius:24px;overflow:hidden;background:color-mix(in srgb,var(--panel) 88%,transparent)}.panel>div{padding:22px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.panel>div:nth-child(3n){border-right:0}.panel>div:nth-last-child(-n+3){border-bottom:0}.label{display:block;color:var(--muted);font-size:.78rem;text-transform:uppercase;letter-spacing:.08em}.panel strong{display:block;margin-top:8px;overflow-wrap:anywhere}.status.good{color:var(--accent)}.status.bad{color:#ff8a8a}.note{margin:32px 0 90px;padding:28px;border:1px solid var(--line);border-radius:20px;background:var(--panel)}.note h2{margin-top:0}.prose{max-width:760px;margin-top:72px}.prose h1{font-size:clamp(2.4rem,7vw,4.5rem)}footer{padding:28px 0 42px;color:var(--muted);border-top:1px solid var(--line)}@media(max-width:720px){.nav nav{display:none}.hero{padding-top:56px}.panel{grid-template-columns:1fr 1fr}.panel>div,.panel>div:nth-child(3n),.panel>div:nth-last-child(-n+3){border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.panel>div:nth-child(2n){border-right:0}.panel>div:nth-last-child(-n+2){border-bottom:0}}
EOF
    cat >"${INSTALL_DIR}/site/diagnostics.js" <<'EOF'
const $=id=>document.getElementById(id), report={};
function set(id,value){$(id).textContent=value;report[id]=value}
function localState(){set('host',location.hostname);set('online',navigator.onLine?'online':'offline');set('secure',isSecureContext?'secure context':'not secure')}
async function run(){const button=$('run');button.disabled=true;set('result','running');$('result').className='status';const samples=[];try{for(let i=0;i<5;i++){const start=performance.now();const response=await fetch('/health.txt?probe='+Date.now(),{cache:'no-store'});if(!response.ok)throw new Error('HTTP '+response.status);await response.text();samples.push(performance.now()-start)}samples.sort((a,b)=>a-b);set('latency',Math.round(samples[2])+' ms');set('checked',new Date().toLocaleString());set('result','healthy');$('result').className='status good'}catch(error){set('latency','unavailable');set('checked',new Date().toLocaleString());set('result','failed: '+error.message);$('result').className='status bad'}finally{button.disabled=false}}
$('run').addEventListener('click',run);$('copy').addEventListener('click',async()=>{const text=['Northstar network report',...Object.entries(report).map(([k,v])=>k+': '+v)].join('\n');try{await navigator.clipboard.writeText(text);$('copy').textContent='Copied'}catch{$('copy').textContent='Copy unavailable'}});addEventListener('online',localState);addEventListener('offline',localState);localState();run();
EOF
    cat >"${INSTALL_DIR}/site/favicon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#0f2034"/><path d="M32 7l5.7 18.7L57 32l-19.3 6.3L32 57l-5.7-18.7L7 32l19.3-6.3z" fill="#5ee6b0"/><circle cx="32" cy="32" r="5" fill="#07111f"/></svg>
EOF
    cat >"${INSTALL_DIR}/site/robots.txt" <<'EOF'
User-agent: *
Allow: /
Sitemap: /sitemap.xml
EOF
    printf 'ok\n' >"${INSTALL_DIR}/site/health.txt"
    chmod 0644 "${INSTALL_DIR}/site/"*
}

render_compose() {
    local host_cpus node_cpus node_memory
    host_cpus="$(nproc)"
    if ((host_cpus >= 2)); then node_cpus='1.50'; else node_cpus='0.75'; fi
    if (( $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) >= 3500 )); then node_memory='2g'; else node_memory='1g'; fi

    cat >"${INSTALL_DIR}/docker-compose.node.yml" <<EOF
name: ${COMPOSE_PROJECT}-node
services:
  node:
    image: ${NODE_IMAGE}
    pull_policy: never
    container_name: ${NODE_CONTAINER}
    network_mode: host
    restart: unless-stopped
    cpus: ${node_cpus}
    mem_limit: ${node_memory}
    pids_limit: 512
    env_file:
      - ./private/node.env
    cap_drop:
      - NET_ADMIN
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: local
      options:
        max-size: 10m
        max-file: "3"
EOF

    cat >"${INSTALL_DIR}/docker-compose.edge.yml" <<EOF
name: ${COMPOSE_PROJECT}
services:
  caddy:
    image: ${CADDY_IMAGE}
    pull_policy: never
    container_name: ${CADDY_CONTAINER}
    network_mode: host
    restart: unless-stopped
    cpus: 0.75
    mem_limit: 384m
    pids_limit: 256
    env_file:
      - ./private/edge.env
    command: ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
    read_only: true
    cap_drop: ["ALL"]
    # The official Caddy binary carries cap_net_bind_service as a file
    # capability. Docker must include it in the bounding set even though this
    # instance binds only high loopback ports; otherwise execve returns EPERM.
    cap_add: ["NET_BIND_SERVICE"]
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    tmpfs:
      - /config:size=8m,mode=0700
      - /run:size=1m,mode=0700
    logging:
      driver: local
      options:
        max-size: 10m
        max-file: "3"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - ./site:/srv:ro

  haproxy:
    image: ${HAPROXY_IMAGE}
    pull_policy: never
    container_name: ${HAPROXY_CONTAINER}
    user: "0:0"
    network_mode: host
    restart: unless-stopped
    cpus: 0.50
    mem_limit: 256m
    pids_limit: 256
    env_file:
      - ./private/edge.env
    command: ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
    read_only: true
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE", "SETUID", "SETGID"]
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    tmpfs:
      - /run:size=8m,mode=0755
    logging:
      driver: local
      options:
        max-size: 10m
        max-file: "3"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro

volumes:
  caddy_data:
    name: ${COMPOSE_PROJECT}-caddy-data
EOF
    chmod 0644 "${INSTALL_DIR}/docker-compose.node.yml" "${INSTALL_DIR}/docker-compose.edge.yml"
}

render_finalmask() {
    # Client-side only.  Never paste this into the Config Profile/server
    # inbound on Xray 26.6.27.
    cat >"${INSTALL_DIR}/finalmask-fragment-canary.json" <<'EOF'
{
  "tcp": [
    {
      "type": "fragment",
      "settings": {
        "packets": "tlshello",
        "lengths": ["5-10", "10-20", "20-40"],
        "delays": ["0-2"],
        "maxSplit": "3-5"
      }
    }
  ]
}
EOF
    chmod 0644 "${INSTALL_DIR}/finalmask-fragment-canary.json"
}

render_tuning() {
    cat >"${INSTALL_DIR}/99-remnawave-edge.conf" <<'EOF'
# Conservative transport baseline. This improves queueing/headroom; it is not
# a TSPU bypass and should still be measured under real load.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
    chmod 0644 "${INSTALL_DIR}/99-remnawave-edge.conf"
}

render_happ_rules() {
    # Panel 2.8.1 already recognises Happ/* and INCY/* as JSON-capable clients
    # when "Serve JSON at base subscription" is enabled.  Generating a global
    # first-match Response Rule here would be a needless, high-blast-radius
    # change and could override an administrator's existing rules.
    cat >"${PRIVATE_DIR}/SUBSCRIPTION-SETTINGS.txt" <<'EOF'
Remnawave 2.8.1 subscription settings

1. Enable: Serve JSON at base subscription.
2. Keep the existing system Response Rules in their current order.
3. Do not add a new Happ/INCY rule for this deployment.
4. Keep happRouting empty; routing and DNS are in the XRAY_JSON template.
5. Test with the normal base subscription URL, not a forced /json suffix.
EOF
    chmod 0600 "${PRIVATE_DIR}/SUBSCRIPTION-SETTINGS.txt"
}

render_auto_template() {
    local raw_uuid='__RAW_HOST_UUID__'
    local raw_fragment_uuid='__RAW_FRAGMENT_HOST_UUID__'
    local xhttp_uuid='__XHTTP_HOST_UUID__'
    local inject_placeholders
    local output="${PRIVATE_DIR}/xray-json-auto.template.json"
    inject_placeholders="\"${raw_uuid}\", \"${xhttp_uuid}\""
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        inject_placeholders="\"${raw_uuid}\", \"${raw_fragment_uuid}\", \"${xhttp_uuid}\""
    fi
    cat >"${output}" <<EOF
{
  "remnawave": {
    "injectHosts": [
      {
        "selector": {
          "type": "uuids",
          "values": [${inject_placeholders}]
        },
        "selectFrom": "HIDDEN",
        "tagPrefix": "proxy"
      }
    ]
  },
  "log": {"loglevel": "warning"},
  "fakedns": {
    "ipPool": "198.18.0.0/15",
    "poolSize": 8192
  },
  "dns": {
    "tag": "dns-internal",
    "queryStrategy": "UseIPv4",
    "disableCache": false,
    "serveStale": true,
    "serveExpiredTTL": 86400,
    "disableFallbackIfMatch": false,
    "enableParallelQuery": true,
    "useSystemHosts": false,
    "hosts": {
      "1.1.1.1": "1.1.1.1",
      "8.8.8.8": "8.8.8.8",
      "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"],
      "dns.google": ["8.8.8.8", "8.8.4.4"]
    },
    "servers": [
      {"address": "https://1.1.1.1/dns-query", "timeoutMs": 2000},
      {"address": "https://8.8.8.8/dns-query", "timeoutMs": 2500},
      {"address": "fakedns", "domains": ["regexp:.*"], "skipFallback": true}
    ]
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true},
      "sniffing": {"enabled": true, "destOverride": ["fakedns", "http", "tls", "quic"], "routeOnly": false}
    },
    {
      "tag": "http-in",
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http",
      "sniffing": {"enabled": true, "destOverride": ["fakedns", "http", "tls"], "routeOnly": false}
    },
    {
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "port": 10853,
      "protocol": "dokodemo-door",
      "settings": {"address": "1.1.1.1", "port": 53, "network": "tcp,udp"}
    }
  ],
  "burstObservatory": {
    "subjectSelector": ["proxy"],
    "pingConfig": {
      "destination": "https://8.8.8.8/generate_204",
      "connectivity": "",
      "interval": "15s",
      "sampling": 2,
      "timeout": "4s",
      "httpMethod": "HEAD"
    }
  },
  "routing": {
    "domainStrategy": "AsIs",
    "balancers": [
      {
        "tag": "RU_AUTO",
        "selector": ["proxy"],
        "fallbackTag": "proxy",
        "strategy": {"type": "leastPing"}
      }
    ],
    "rules": [
      {"type": "field", "inboundTag": ["dns-internal"], "balancerTag": "RU_AUTO"},
      {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"},
      {"type": "field", "network": "tcp,udp", "port": 53, "outboundTag": "dns-out"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "network": "tcp,udp", "balancerTag": "RU_AUTO"}
    ]
  },
  "outbounds": [
    {
      "tag": "dns-out",
      "protocol": "dns",
      "settings": {
        "rules": [
          {"qType": "1,28", "action": "hijack"},
          {"rCode": 0, "action": "return"}
        ]
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
EOF
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        jq '.remnawave.injectHosts[0].selector.values += ["__HYSTERIA_HOST_UUID__"]' \
            "${output}" >"${output}.tmp"
        mv -f "${output}.tmp" "${output}"
    fi
    if [[ "${BLOCK_CLIENT_QUIC}" == 1 ]]; then
        jq '.routing.rules |=
          (.[0:3] + [{type:"field", network:"udp", port:443, outboundTag:"block"}] + .[3:])' \
            "${output}" >"${output}.tmp"
        mv -f "${output}.tmp" "${output}"
    fi
    chmod 0600 "${output}"
    if [[ -n "${RAW_HOST_UUID:-}" && -n "${XHTTP_HOST_UUID:-}" && \
          ( "${ENABLE_RAW_FRAGMENT}" != 1 || -n "${RAW_FRAGMENT_HOST_UUID:-}" ) && \
          ( "${ENABLE_HYSTERIA}" != 1 || -n "${HYSTERIA_HOST_UUID:-}" ) ]]; then
        jq --arg raw "${RAW_HOST_UUID}" --arg raw_fragment "${RAW_FRAGMENT_HOST_UUID:-}" \
            --arg xhttp "${XHTTP_HOST_UUID}" \
            --arg hysteria "${HYSTERIA_HOST_UUID:-}" \
            --argjson enable_fragment "${ENABLE_RAW_FRAGMENT}" \
            --argjson enable_hysteria "${ENABLE_HYSTERIA}" \
            --arg extra "${EXTRA_HOST_UUIDS:-}" '
            ($extra | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))) as $extra_hosts |
            .remnawave.injectHosts[0].selector.values =
              ([$raw] +
               (if $enable_fragment == 1 then [$raw_fragment] else [] end) +
               [$xhttp] +
               (if $enable_hysteria == 1 then [$hysteria] else [] end) +
               $extra_hosts)
        ' \
            "${output}" >"${PRIVATE_DIR}/xray-json-auto.ready.json"
        chmod 0600 "${PRIVATE_DIR}/xray-json-auto.ready.json"
    fi
}

render_panel_stage_one() {
    local hysteria_tag_line='' active_inbounds="${RAW_TAG}, ${XHTTP_TAG}"
    local hysteria_host='' fragment_host=''
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        fragment_host="
5. PHYSICAL HOST — RAW REALITY / FIREFOX / CLIENT FRAGMENT
   This is a second client representation of the SAME RAW inbound. It does not
   create another listener and does not require another user credential.

   Remark: RW ${NODE_CODE} RAW FF FRAGMENT
   Inbound: ${RAW_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Advanced -> FinalMask: paste the whole object from:
     ${INSTALL_DIR}/finalmask-fragment-canary.json
   Leave SNI, Host, Path, ALPN, Security Layer, Mux, SockOpt and Vless Route ID
   at their defaults/empty values.
   Host Visibility: ON (enabled)
   Hide Host: ON
   Tag: ${NODE_CODE}:RAW:FF:FRAG (optional, administrative only)
   Nodes: optional visual metadata

   IMPORTANT: FinalMask belongs only to this Host/client. Never paste it into
   the Config Profile or a server REALITY inbound on Xray 26.6.27."
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        hysteria_tag_line="   - ${HYSTERIA_TAG}"
        active_inbounds="${active_inbounds}, ${HYSTERIA_TAG}"
        hysteria_host="
7. PHYSICAL HOST — HYSTERIA2 / UDP 443
   Remark: RW ${NODE_CODE} HY2
   Inbound: ${HYSTERIA_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> SNI: ${XHTTP_SNI}
   Advanced -> Security Layer: TLS
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Advanced -> ALPN: h3
   Advanced -> Pinned Peer Certificate SHA256: ${HYSTERIA_CERT_SHA256}
   Leave Host, Path, Mux, SockOpt, FinalMask and Vless Route ID empty/default.
   Host Visibility: ON (enabled)
   Hide Host: ON
   Tag: ${NODE_CODE}:HY2 (optional, administrative only)
   Nodes: optional visual metadata

The certificate is a generated CA:FALSE leaf and is authenticated by the pin;
do not enable allowInsecure. UDP hopping and Salamander are intentionally off."
    fi
    cat >"${PRIVATE_DIR}/PANEL-STAGE-1.txt" <<EOF
REMNAWAVE PANEL 2.8.1 — STAGE 1
================================

1. CONFIG PROFILE
   Config Profiles -> Create
   Name: ${PROFILE_NAME}
   Paste the whole file:
   ${PRIVATE_DIR}/config-profile.ready.json

   Expected inbound tags:
   - ${RAW_TAG}
   - ${XHTTP_TAG}
${hysteria_tag_line}

2. NODE
   Internal name: RW-${NODE_CODE}
   Country: choose the actual server country
   Address: ${EDGE_IPV4}
   Port: ${NODE_PORT}
   Config Profile: ${PROFILE_NAME}
   Active Inbounds: ${active_inbounds}
   Plugin: None / disabled
   Tags: ${NODE_CODE}:EDGE (optional, administrative only)
   Traffic multipliers: 1.0 / 1.0

   Save the Node, copy the newly issued SECRET_KEY, then run:
   sudo bash <this-script> node

3. ACCESS AFTER NODE IS ONLINE
   Create an Internal Squad such as RW-${NODE_CODE}-CANARY.
   Attach exactly these active inbounds: ${active_inbounds}.
   Add one ACTIVE canary user to that squad. HWID should be off for the first test.

4. PHYSICAL HOST — RAW REALITY
   Remark: RW ${NODE_CODE} RAW FF
   Inbound: ${RAW_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Leave SNI, Host, Path, ALPN, Security Layer, Mux, SockOpt, FinalMask and
   Vless Route ID at their defaults/empty values. Panel 2.8.1 derives SNI,
   REALITY public key, shortId and Vision flow from the selected inbound.
   Host Visibility: ON (enabled)
   Hide Host: ON
   Tag: ${NODE_CODE}:RAW:FF (optional, administrative only)
   Nodes: optional visual metadata

${fragment_host}

6. PHYSICAL HOST — TLS/XHTTP
   Remark: RW ${NODE_CODE} XHTTP FF
   Inbound: ${XHTTP_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> SNI: ${XHTTP_SNI}
   Advanced -> Host: ${XHTTP_SNI}
   Advanced -> Security Layer: TLS
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Advanced -> ALPN: h2
   Leave Path empty: Panel inherits ${XHTTP_PATH} from the inbound. Mode is
   inherited as packet-up. Leave XHTTP Extra Params, Mux, SockOpt, FinalMask
   and Vless Route ID empty/default.
   Host Visibility: ON (enabled)
   Hide Host: ON
   Tag: ${NODE_CODE}:XHTTP:FF (optional, administrative only)
   Nodes: optional visual metadata

${hysteria_host}

Save all enabled physical Hosts and copy their HOST UUID values (not user UUID
and not inbound UUID).
Then run: sudo bash <this-script> template

Do not type a public key, shortId, flow or any "public id" into a Host. Those
values are generated/inherited by Remnawave 2.8.1 from the selected inbound.
EOF
    chmod 0600 "${PRIVATE_DIR}/PANEL-STAGE-1.txt"
}

render_panel_stage_two() {
    [[ -n "${RAW_HOST_UUID:-}" && -n "${XHTTP_HOST_UUID:-}" ]] || return 0
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 || -n "${RAW_FRAGMENT_HOST_UUID:-}" ]] || return 0
    [[ "${ENABLE_HYSTERIA}" != 1 || -n "${HYSTERIA_HOST_UUID:-}" ]] || return 0
    local hysteria_uuid_line='' fragment_uuid_line='' physical_count=2
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        fragment_uuid_line="Physical RAW Fragment Host UUID: ${RAW_FRAGMENT_HOST_UUID}"
        physical_count=$((physical_count + 1))
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        hysteria_uuid_line="Physical Hysteria2 Host UUID: ${HYSTERIA_HOST_UUID}"
        physical_count=$((physical_count + 1))
    fi
    cat >"${PRIVATE_DIR}/PANEL-STAGE-2.txt" <<EOF
REMNAWAVE PANEL 2.8.1 — STAGE 2
================================

Physical RAW Host UUID: ${RAW_HOST_UUID}
${fragment_uuid_line}
Physical XHTTP Host UUID: ${XHTTP_HOST_UUID}
${hysteria_uuid_line}
Additional physical Host UUIDs: ${EXTRA_HOST_UUIDS:-none}

1. XRAY_JSON TEMPLATE
   Create template: RW-${NODE_CODE}-AUTO
   Paste the whole strict JSON file:
   ${PRIVATE_DIR}/xray-json-auto.ready.json

2. AUTO HOST
   A Host cannot exist without an inbound in Panel 2.8.1. Bind this carrier Host
   to ${RAW_TAG}; the template does not add the carrier as an outbound.

   Remark: RW ${NODE_CODE} AUTO
   Inbound: ${RAW_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Xray JSON Template: RW-${NODE_CODE}-AUTO
   Leave every Advanced connection override at its default/empty value. This
   carrier exists only because Panel 2.8.1 requires every Host to have an
   inbound; the template intentionally does not emit it as another outbound.
   Host Visibility: ON (enabled)
   Hide Host: OFF
   Tag: ${NODE_CODE}:AUTO (optional, administrative only)
   Exclude formats: every format except XRAY_JSON
   Exclude production squads during canary

   Do NOT inject the AUTO Host UUID into the template. Only the ${physical_count}
   enabled physical UUIDs above belong in remnawave.injectHosts.

   For real multi-node failover, add physical Host UUIDs from nodes in other
   providers/ASNs to the same values array. On this server you can regenerate it
   with RW_EXTRA_HOST_UUIDS=uuid3,uuid4 and rerun the template stage. This is
   health-aware leastPing; DNS round-robin and Host.address lists are not.

3. HAPP / INCY SUBSCRIPTION AND DNS
   Subscription Settings -> Serve JSON at base subscription: ON.
   Keep your existing built-in Response Rules unchanged. Do not add a scoped
   Happ rule and do not replace Fallback Base64: Backend 2.8.1 recognizes both
   Happ and INCY as native XRAY_JSON fallback clients when JSON-at-base is ON.
   Keep happRouting empty. Give users the normal base subscription URL; no
   /json suffix or per-user action is required beyond Refresh/Update.
   Reference generated by the wizard:
   ${PRIVATE_DIR}/SUBSCRIPTION-SETTINGS.txt

   The client template captures port 53 and resolves through Cloudflare/Google
   DoH inside the selected tunnel. It does not send plaintext DNS directly as a
   fallback. Test with a physical-interface packet capture as well as a DNS
   leak test: the latter alone cannot prove which interface carried a query.

4. BASELINE FIRST
   Keep FinalMask empty on normal RAW, XHTTP and Hysteria2 Hosts. The optional
   hidden RAW Fragment Host is the isolated A/B canary and uses:
   ${INSTALL_DIR}/finalmask-fragment-canary.json
   Never put that object in the server Config Profile. Client fragmentation can
   change a ClientHello signature; it cannot repair an IP/ASN route drop or a
   Panel <-> Node N/A control-plane outage.

After saving the template and AUTO Host, run:
   sudo bash <this-script> edge
   sudo bash <this-script> verify-auth
EOF
    chmod 0600 "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
}

render_all_files() {
    install -d -m 0755 "${INSTALL_DIR}"
    install -d -m 0700 "${PRIVATE_DIR}"
    render_profile
    render_edge_env
    render_haproxy
    render_caddy
    render_site
    render_compose
    render_finalmask
    render_tuning
    render_happ_rules
    render_auto_template
    render_panel_stage_one
    render_panel_stage_two
}

snapshot_generated_artifacts() {
    local snapshot_dir="$1" rel target
    local artifacts=(
      Caddyfile haproxy.cfg docker-compose.node.yml docker-compose.edge.yml
      finalmask-fragment-canary.json 99-remnawave-edge.conf site
      private/config-profile.ready.json private/edge.env
      private/xray-json-auto.template.json private/xray-json-auto.ready.json
      private/SUBSCRIPTION-SETTINGS.txt private/PANEL-STAGE-1.txt private/PANEL-STAGE-2.txt
    )
    : >"${snapshot_dir}/manifest"
    for rel in "${artifacts[@]}"; do
        target="${INSTALL_DIR}/${rel}"
        if [[ -e "${target}" ]]; then
            printf 'present %s\n' "${rel}" >>"${snapshot_dir}/manifest"
            cp -a --parents "${target}" "${snapshot_dir}"
        else
            printf 'absent %s\n' "${rel}" >>"${snapshot_dir}/manifest"
        fi
    done
    chmod 0600 "${snapshot_dir}/manifest"
}

restore_generated_artifacts() {
    local snapshot_dir="$1" status rel target backup
    while read -r status rel; do
        target="${INSTALL_DIR}/${rel}"
        backup="${snapshot_dir}${target}"
        case "${status}" in
            present)
                if [[ -d "${target}" ]]; then find "${target}" -depth -delete; fi
                install -d -m 0700 "$(dirname "${target}")"
                cp -a -- "${backup}" "${target}"
                ;;
            absent)
                [[ ! -e "${target}" ]] || find "${target}" -depth -delete
                ;;
        esac
    done <"${snapshot_dir}/manifest"
}

render_validate_transaction() {
    local snapshot_dir
    install -d -m 0700 "${PRIVATE_DIR}"
    snapshot_dir="$(mktemp -d "${PRIVATE_DIR}/.render-backup.XXXXXX")"
    snapshot_generated_artifacts "${snapshot_dir}"
    if ! (
        render_all_files
        ensure_node_env_placeholder
        check_dns
        validate_artifacts
    ); then
        warn 'Render or validation failed; restoring the previous generated artifact set.'
        restore_generated_artifacts "${snapshot_dir}"
        find "${snapshot_dir}" -depth -delete
        die 'Generated artifacts were not committed.'
    fi
    find "${snapshot_dir}" -depth -delete
}

ensure_node_env_placeholder() {
    if [[ ! -f "${PRIVATE_DIR}/node.env" ]]; then
        write_node_env '__PANEL_SECRET_REQUIRED__'
    else
        [[ ! -L "${PRIVATE_DIR}/node.env" ]] || die 'node.env must not be a symlink.'
        [[ "$(stat -c '%a' "${PRIVATE_DIR}/node.env")" == 600 ]] || die 'node.env must have mode 0600.'
        [[ "$(stat -c '%u' "${PRIVATE_DIR}/node.env")" == 0 ]] || die 'node.env must be owned by root.'
    fi
}

write_node_env() {
    local secret="$1" env_tmp
    install -d -m 0700 "${PRIVATE_DIR}"
    env_tmp="$(mktemp "${PRIVATE_DIR}/.node.env.XXXXXX")"
    if ! {
        printf 'SECRET_KEY=%s\n' "${secret}"
        printf 'NODE_PORT=%s\n' "${NODE_PORT}"
    } >"${env_tmp}"; then
        truncate -s 0 "${env_tmp}" 2>/dev/null || true
        find "${env_tmp}" -maxdepth 0 -delete 2>/dev/null || true
        return 1
    fi
    chmod 0600 "${env_tmp}"
    mv -f -- "${env_tmp}" "${PRIVATE_DIR}/node.env"
}

validate_auto_template_model() {
    local template="$1" temp_dir test_uuid injected finalmask xhttp_tag hysteria_tag
    temp_dir="$(mktemp -d)"
    test_uuid="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" uuid | tr -d '\r\n')"
    injected="${temp_dir}/client-injected.json"
    finalmask="${temp_dir}/client-finalmask.json"
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        xhttp_tag='proxy-3'
        hysteria_tag='proxy-4'
    else
        xhttp_tag='proxy-2'
        hysteria_tag='proxy-3'
    fi
    jq --arg uuid "${test_uuid}" --arg public_key "${REALITY_PUBLIC_KEY}" \
        --arg short_id "${REALITY_SHORT_ID}" --arg fingerprint "${CLIENT_FINGERPRINT}" \
        --arg xhttp_tag "${xhttp_tag}" '
        del(.remnawave) |
        .outbounds = ([
          {
            tag: "proxy", protocol: "vless",
            settings: {vnext: [{address: "127.0.0.1", port: 10443, users: [{id: $uuid, encryption: "none", flow: "xtls-rprx-vision"}]}]},
            streamSettings: {network: "raw", security: "reality", realitySettings: {fingerprint: $fingerprint, serverName: "reality.test", publicKey: $public_key, shortId: $short_id, spiderX: "/"}}
          },
          {
            tag: $xhttp_tag, protocol: "vless",
            settings: {vnext: [{address: "127.0.0.1", port: 10443, users: [{id: $uuid, encryption: "none"}]}]},
            streamSettings: {network: "xhttp", security: "tls", tlsSettings: {serverName: "xhttp.test", fingerprint: $fingerprint, alpn: ["h2"]}, xhttpSettings: {host: "xhttp.test", path: "/api/v1/test/", mode: "packet-up"}}
          }
        ] + .outbounds)
    ' "${template}" >"${injected}"
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        jq --slurpfile fm "${INSTALL_DIR}/finalmask-fragment-canary.json" '
          (.outbounds[0] | .tag = "proxy-2" | .streamSettings.finalmask = $fm[0]) as $fragment |
          .outbounds = [.["outbounds"][0], $fragment] + .outbounds[1:]
        ' "${injected}" >"${injected}.tmp"
        mv -f "${injected}.tmp" "${injected}"
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        jq --arg uuid "${test_uuid}" --arg pin "${HYSTERIA_CERT_SHA256}" \
          --arg fingerprint "${CLIENT_FINGERPRINT}" --arg hysteria_tag "${hysteria_tag}" '
          .outbounds = ([{
            tag: $hysteria_tag,
            protocol: "hysteria",
            settings: {address: "127.0.0.1", port: 443, version: 2},
            streamSettings: {
              network: "hysteria",
              security: "tls",
              tlsSettings: {
                serverName: "xhttp.test",
                fingerprint: $fingerprint,
                alpn: ["h3"],
                pinnedPeerCertSha256: $pin
              },
              hysteriaSettings: {version: 2, auth: $uuid}
            }
          }] + .outbounds)
        ' "${injected}" >"${injected}.tmp"
        mv -f "${injected}.tmp" "${injected}"
    fi
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
        -v "${injected}:/etc/xray/config.json:ro" \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -test -config /etc/xray/config.json >/dev/null
    jq --slurpfile fm "${INSTALL_DIR}/finalmask-fragment-canary.json" \
        '(.outbounds[] | select(.protocol == "vless" and .streamSettings.network == "raw") |
          .streamSettings.finalmask) = $fm[0]' \
        "${injected}" >"${finalmask}"
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
        -v "${finalmask}:/etc/xray/config.json:ro" \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -test -config /etc/xray/config.json >/dev/null
    rm -rf -- "${temp_dir}"
}

validate_artifacts() {
    local caddy_output caddy_json
    log 'Validating strict JSON, pinned Xray, Compose, HAProxy and Caddy...'
    jq empty "${PRIVATE_DIR}/config-profile.ready.json"
    jq empty "${PRIVATE_DIR}/xray-json-auto.template.json"
    jq empty "${INSTALL_DIR}/finalmask-fragment-canary.json"
    [[ ! -f "${PRIVATE_DIR}/xray-json-auto.ready.json" ]] || \
        jq empty "${PRIVATE_DIR}/xray-json-auto.ready.json"

    jq -e --arg raw "${RAW_TAG}" --arg xhttp "${XHTTP_TAG}" \
      --arg path "${XHTTP_PATH}" '
      ([.inbounds[] | select(.tag == $raw)] | length == 1) and
      ([.inbounds[] | select(.tag == $xhttp)] | length == 1) and
      (.inbounds[] | select(.tag == $raw) |
        .listen == "127.0.0.1" and .streamSettings.network == "raw" and
        .streamSettings.security == "reality" and
        (.settings | has("flow") | not)) and
      (.inbounds[] | select(.tag == $xhttp) |
        .listen == "127.0.0.1" and .streamSettings.network == "xhttp" and
        .streamSettings.security == "none" and
        .streamSettings.xhttpSettings.mode == "packet-up" and
        .streamSettings.xhttpSettings.path == $path and
        (.settings | has("flow") | not)) and
      (all(.inbounds[]; (.streamSettings | has("finalmask") | not)))
    ' "${PRIVATE_DIR}/config-profile.ready.json" >/dev/null || \
        die 'Server profile lost its loopback/no-manual-flow/no-server-FinalMask contract.'

    jq -e '
      .remnawave.injectHosts[0].selectFrom == "HIDDEN" and
      .routing.balancers[0].strategy.type == "leastPing" and
      (.dns.servers | length == 3) and
      (.dns.servers[0].address | startswith("https://")) and
      (.dns.servers[1].address | startswith("https://")) and
      .dns.servers[2].address == "fakedns"
    ' "${PRIVATE_DIR}/xray-json-auto.template.json" >/dev/null || \
        die 'AUTO template lost its hidden-Host, leastPing or DoH-only contract.'

    docker run --rm --pull never --network none --cap-drop ALL --read-only \
        -v "${PRIVATE_DIR}/config-profile.ready.json:/etc/xray/config.json:ro" \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -test -config /etc/xray/config.json >/dev/null

    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        validate_hysteria_material
    fi

    validate_auto_template_model "${PRIVATE_DIR}/xray-json-auto.template.json"
    docker compose --env-file "${PRIVATE_DIR}/edge.env" \
        -f "${INSTALL_DIR}/docker-compose.edge.yml" config --quiet
    docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" config --quiet

    docker run --rm --pull never --network none --cap-drop ALL --read-only \
        --env-file "${PRIVATE_DIR}/edge.env" \
        -v "${INSTALL_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
        "${HAPROXY_IMAGE}" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null

    if ! caddy_output="$(docker run --rm --pull never --network none --cap-drop ALL --cap-add NET_BIND_SERVICE --read-only \
        --tmpfs /data:rw,noexec,nosuid,size=8m \
        --tmpfs /config:rw,noexec,nosuid,size=2m \
        --tmpfs /run:rw,noexec,nosuid,size=1m \
        --env-file "${PRIVATE_DIR}/edge.env" \
        -v "${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "${INSTALL_DIR}/site:/srv:ro" \
        "${CADDY_IMAGE}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
        printf '%s\n' "${caddy_output}" >&2
        die 'Caddy validation failed.'
    fi
    caddy_json="$(docker run --rm --pull never --network none --cap-drop ALL --cap-add NET_BIND_SERVICE --read-only \
        --tmpfs /data:rw,noexec,nosuid,size=8m \
        --tmpfs /config:rw,noexec,nosuid,size=2m \
        --tmpfs /run:rw,noexec,nosuid,size=1m \
        --env-file "${PRIVATE_DIR}/edge.env" \
        -v "${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "${INSTALL_DIR}/site:/srv:ro" \
        "${CADDY_IMAGE}" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null)"
    jq -e --arg reality "${REALITY_SNI}" --arg xhttp "${XHTTP_SNI}" '
      ([.apps.tls.automation.policies[].issuers[] |
        select(.module == "acme" and .challenges.http.disabled == true and
        .challenges."tls-alpn".alternate_port == 19443)] | length == 1) and
      ((.apps.tls.automation.policies[0].subjects | sort) == ([$reality, $xhttp] | sort)) and
      ([.apps.http.servers[].listen[]] | index("127.0.0.1:19443") != null) and
      ([.apps.http.servers[].listen[]] | index("0.0.0.0:19443") == null)
    ' <<<"${caddy_json}" >/dev/null || \
        die 'Caddy lost its two-subject TLS-ALPN or loopback-only listener contract.'
    log 'Artifact validation passed.'
}

find_authoritative_nameservers() {
    local name="$1" candidate ns
    candidate="${name}"
    while [[ "${candidate}" == *.* ]]; do
        ns="$(dig +short NS "${candidate}" | sed 's/\.$//' | sort -u)"
        if [[ -n "${ns}" ]]; then
            printf '%s\n' "${ns}"
            return 0
        fi
        candidate="${candidate#*.}"
    done
    return 1
}

check_one_domain_dns() {
    local domain="$1" resolver answer nameservers ns authoritative_seen=0
    nameservers="$(find_authoritative_nameservers "${domain}")" || \
        die "No authoritative nameserver found for ${domain}."
    while IFS= read -r ns; do
        [[ -n "${ns}" ]] || continue
        answer="$(dig +time=4 +tries=1 +short @"${ns}" A "${domain}" | sort -u)"
        [[ "${answer}" == "${EDGE_IPV4}" ]] || \
            die "Authoritative DNS ${ns} gives '${answer:-no A}' for ${domain}; expected ${EDGE_IPV4}."
        [[ -z "$(dig +time=4 +tries=1 +short @"${ns}" AAAA "${domain}" | sort -u)" ]] || \
            die "${domain} has AAAA but this IPv4-only edge does not serve IPv6."
        authoritative_seen=1
    done <<<"${nameservers}"
    ((authoritative_seen == 1)) || die "Could not verify authoritative DNS for ${domain}."

    for resolver in 1.1.1.1 8.8.8.8; do
        answer="$(dig +time=4 +tries=1 +short @"${resolver}" A "${domain}" | sort -u)"
        [[ "${answer}" == "${EDGE_IPV4}" ]] || \
            die "Resolver ${resolver} gives '${answer:-no A}' for ${domain}; expected ${EDGE_IPV4}."
        [[ -z "$(dig +time=4 +tries=1 +short @"${resolver}" AAAA "${domain}" | sort -u)" ]] || \
            die "Resolver ${resolver} sees unsupported AAAA for ${domain}."
    done
}

check_dns() {
    if [[ "${SKIP_DNS}" == 1 ]]; then
        warn 'DNS checks skipped by RW_SKIP_DNS=1.'
        return 0
    fi
    log 'Checking authoritative DNS and two independent recursive resolvers...'
    check_one_domain_dns "${REALITY_SNI}"
    check_one_domain_dns "${XHTTP_SNI}"
    log 'DNS checks passed.'
}

port_is_listening() {
    ss -H -ltn "sport = :$1" | grep -Fq .
}

udp_port_is_listening() {
    ss -H -lun "sport = :$1" | grep -Fq .
}

port_is_loopback_only() {
    local port="$1"
    ss -H -ltn "sport = :${port}" | awk -v p=":${port}" '
        $4 != "127.0.0.1" p && $4 != "[::1]" p {bad=1}
        END {exit bad}
    '
}

container_is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]]
}

tcp_port_owned_by_container() {
    local port="$1" container="$2" container_id pid
    container_id="$(docker inspect -f '{{.Id}}' "${container}" 2>/dev/null || true)"
    [[ -n "${container_id}" ]] || return 1
    while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cgroup" ]] || continue
        grep -Fq "${container_id}" "/proc/${pid}/cgroup" && return 0
    done < <(ss -H -ltnp "sport = :${port}" 2>/dev/null | \
        sed -nE 's/.*pid=([0-9]+).*/\1/p' | sort -u)
    return 1
}

udp_port_owned_by_container() {
    local port="$1" container="$2" container_id pid
    container_id="$(docker inspect -f '{{.Id}}' "${container}" 2>/dev/null || true)"
    [[ -n "${container_id}" ]] || return 1
    while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cgroup" ]] || continue
        grep -Fq "${container_id}" "/proc/${pid}/cgroup" && return 0
    done < <(ss -H -lunp "sport = :${port}" 2>/dev/null | \
        sed -nE 's/.*pid=([0-9]+).*/\1/p' | sort -u)
    return 1
}

assert_port_free_or_owned() {
    local port="$1" owner="$2"
    if port_is_listening "${port}"; then
        if ! container_is_running "${owner}" || \
           ! tcp_port_owned_by_container "${port}" "${owner}"; then
            die "TCP port ${port} is not owned by the expected container ${owner}."
        fi
    fi
}

snapshot_ufw_state() {
    local label="$1" path
    STAGE_UFW_SNAPSHOT="$(mktemp -d "${PRIVATE_DIR}/.${label}-ufw.XXXXXX")"
    chmod 0700 "${STAGE_UFW_SNAPSHOT}"
    if ufw status | grep -Fq 'Status: active'; then
        printf 'active\n' >"${STAGE_UFW_SNAPSHOT}/status"
    else
        printf 'inactive\n' >"${STAGE_UFW_SNAPSHOT}/status"
    fi
    : >"${STAGE_UFW_SNAPSHOT}/manifest"
    for path in \
        /etc/default/ufw \
        /etc/ufw/user.rules /etc/ufw/user6.rules \
        /etc/ufw/before.rules /etc/ufw/before6.rules \
        /etc/ufw/after.rules /etc/ufw/after6.rules; do
        if [[ -e "${path}" ]]; then
            printf 'present %s\n' "${path}" >>"${STAGE_UFW_SNAPSHOT}/manifest"
            cp -a --parents "${path}" "${STAGE_UFW_SNAPSHOT}"
        else
            printf 'absent %s\n' "${path}" >>"${STAGE_UFW_SNAPSHOT}/manifest"
        fi
    done
    chmod 0600 "${STAGE_UFW_SNAPSHOT}/status" "${STAGE_UFW_SNAPSHOT}/manifest"
}

restore_ufw_state() {
    local status path original_status
    [[ -n "${STAGE_UFW_SNAPSHOT}" && -d "${STAGE_UFW_SNAPSHOT}" ]] || return 0
    while read -r status path; do
        case "${status}" in
            present) cp -a -- "${STAGE_UFW_SNAPSHOT}${path}" "${path}" ;;
            absent)
                case "${path}" in
                    /etc/default/ufw|/etc/ufw/user.rules|/etc/ufw/user6.rules|\
                    /etc/ufw/before.rules|/etc/ufw/before6.rules|\
                    /etc/ufw/after.rules|/etc/ufw/after6.rules)
                        [[ ! -e "${path}" ]] || find "${path}" -maxdepth 0 -delete
                        ;;
                esac
                ;;
        esac
    done <"${STAGE_UFW_SNAPSHOT}/manifest"
    original_status="$(<"${STAGE_UFW_SNAPSHOT}/status")"
    if [[ "${original_status}" == active ]]; then
        ufw --force enable >/dev/null
        ufw reload >/dev/null
    else
        ufw --force disable >/dev/null
    fi
}

discard_stage_snapshot() {
    if [[ -n "${STAGE_UFW_SNAPSHOT}" && -d "${STAGE_UFW_SNAPSHOT}" ]]; then
        find "${STAGE_UFW_SNAPSHOT}" -depth -delete
    fi
    STAGE_UFW_SNAPSHOT=''
}

rollback_failed_stage() {
    local status=$?
    trap - EXIT INT TERM
    if ((status != 0)); then
        warn 'Stage failed; reverting only changes made by this invocation.'
        [[ "${STAGE_STOP_CADDY}" != 1 ]] || docker stop --time 5 "${CADDY_CONTAINER}" >/dev/null 2>&1 || true
        [[ "${STAGE_STOP_HAPROXY}" != 1 ]] || docker stop --time 5 "${HAPROXY_CONTAINER}" >/dev/null 2>&1 || true
        [[ "${STAGE_STOP_NODE}" != 1 ]] || docker stop --time 5 "${NODE_CONTAINER}" >/dev/null 2>&1 || true
        if [[ "${STAGE_TUNING_WAS_NEW}" == 1 ]]; then
            restore_tuning_loaded || true
            for tuning_file in \
                "${PRIVATE_DIR}/sysctl-before.txt" \
                "${PRIVATE_DIR}/sysctl-file.before" \
                "${PRIVATE_DIR}/modules-file.before"; do
                [[ ! -e "${tuning_file}" ]] || find "${tuning_file}" -maxdepth 0 -delete
            done
        fi
        restore_ufw_state || warn 'Automatic UFW restoration failed; use provider console/OOB before disconnecting.'
    fi
    discard_stage_snapshot
    exit "${status}"
}

arm_stage_rollback() {
    local label="$1"
    STAGE_TUNING_WAS_NEW=0
    STAGE_STOP_NODE=0
    STAGE_STOP_HAPROXY=0
    STAGE_STOP_CADDY=0
    [[ "${SKIP_UFW}" == 1 ]] || snapshot_ufw_state "${label}"
    trap rollback_failed_stage EXIT INT TERM
}

commit_stage() {
    trap - EXIT INT TERM
    discard_stage_snapshot
    STAGE_TUNING_WAS_NEW=0
    STAGE_STOP_NODE=0
    STAGE_STOP_HAPROXY=0
    STAGE_STOP_CADDY=0
}

apply_firewall() {
    local status broad=0 ssh_port answer=''
    if [[ "${SKIP_UFW}" == 1 ]]; then
        warn 'UFW changes skipped by RW_SKIP_UFW=1; enforce the equivalent provider firewall yourself.'
        return 0
    fi
    status="$(ufw status verbose)"
    if [[ ! -f "${PRIVATE_DIR}/ufw-initial-status" ]]; then
        if grep -Fq 'Status: active' <<<"${status}"; then
            printf 'active\n' >"${PRIVATE_DIR}/ufw-initial-status"
        else
            printf 'inactive\n' >"${PRIVATE_DIR}/ufw-initial-status"
        fi
        chmod 0600 "${PRIVATE_DIR}/ufw-initial-status"
    fi
    if ! grep -Fq 'Status: active' <<<"${status}"; then
        ssh_port="${RW_SSH_PORT:-}"
        if [[ -z "${ssh_port}" && -n "${SSH_CONNECTION:-}" ]]; then
            ssh_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}")"
        fi
        if [[ -z "${ssh_port}" ]] && command -v sshd >/dev/null 2>&1; then
            ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
        fi
        ssh_port="${ssh_port:-22}"
        if [[ ! "${ssh_port}" =~ ^[0-9]+$ ]] || \
           ((10#${ssh_port} < 1 || 10#${ssh_port} > 65535)); then
            die "Could not determine a safe SSH port; set RW_SSH_PORT."
        fi
        if [[ "${RW_ENABLE_UFW:-0}" != 1 ]]; then
            if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then
                die 'UFW is inactive. Set RW_ENABLE_UFW=1 after confirming RW_SSH_PORT, or enable it manually.'
            fi
            warn "UFW is inactive. The wizard can allow TCP/${ssh_port} for SSH, then enable default-deny incoming."
            confirm_phrase 'This changes the host firewall after preserving SSH access.' ENABLE || \
                die 'UFW initialization was not authorized.'
        fi
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        ufw default deny routed >/dev/null
        ufw allow "${ssh_port}/tcp" comment 'SSH administrative access' >/dev/null
        ufw allow proto tcp from "${PANEL_IPV4}" to any port "${NODE_PORT}" comment "Remnawave Panel ${NODE_CODE}" >/dev/null
        ufw allow 443/tcp comment "Remnawave edge ${NODE_CODE}" >/dev/null
        [[ "${ENABLE_HYSTERIA}" != 1 ]] || \
            ufw allow 443/udp comment "Remnawave Hysteria2 ${NODE_CODE}" >/dev/null
        ufw --force enable >/dev/null
        status="$(ufw status verbose)"
        log "UFW enabled after allowing SSH TCP/${ssh_port}, Panel control and public TCP/443."
    fi
    grep -Eq 'Default: deny \(incoming\)' <<<"${status}" || \
        die 'UFW incoming default is not deny.'

    if ufw status | awk -v p="${NODE_PORT}" '
        ($1 == p || $1 == p"/tcp") && $2 == "ALLOW" {
            if ($0 ~ /Anywhere/ || $0 ~ /0\.0\.0\.0\/0/ || $0 ~ /::\/0/) bad=1
        }
        END {exit !bad}
    '; then
        broad=1
    fi
    if ((broad == 1)) && [[ "${RW_ACCEPT_BROAD_CONTROL:-0}" != 1 ]]; then
        die "A broad UFW allow already exposes Node port ${NODE_PORT}. Remove it or set RW_ACCEPT_BROAD_CONTROL=1 temporarily."
    fi

    ufw allow proto tcp from "${PANEL_IPV4}" to any port "${NODE_PORT}" comment "Remnawave Panel ${NODE_CODE}" >/dev/null
    ufw allow 443/tcp comment "Remnawave edge ${NODE_CODE}" >/dev/null
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || \
        ufw allow 443/udp comment "Remnawave Hysteria2 ${NODE_CODE}" >/dev/null
    ufw status | awk -v p="${NODE_PORT}/tcp" -v ip="${PANEL_IPV4}" '
        $1 == p && $2 == "ALLOW" && index($0, ip) {found=1}
        END {exit !found}
    ' || die 'The exact Panel-IP UFW allow rule was not observed after insertion.'

    for backend in "${RAW_BACKEND_PORT}" "${XHTTP_BACKEND_PORT}" "${CADDY_BACKEND_PORT}" \
        "${HYSTERIA_MASQ_PORT}" "${HAPROXY_STATS_PORT}"; do
        if ufw status | awk -v p="${backend}" '($1 == p || $1 == p"/tcp") && $2 == "ALLOW" {found=1} END {exit !found}'; then
            die "UFW has an external allow for loopback backend port ${backend}; remove that rule."
        fi
    done
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        ufw status | awk '$1 == "443/udp" && $2 == "ALLOW" {found=1} END {exit !found}' || \
            die 'UFW did not expose the selected Hysteria2 UDP/443 transport.'
        log "UFW permits public TCP+UDP/443 and Node API ${NODE_PORT}/tcp only from ${PANEL_IPV4}."
    else
        log "UFW permits public TCP/443 and Node API ${NODE_PORT}/tcp only from ${PANEL_IPV4}."
    fi
}

validate_loaded_state() {
    validate_fqdn "${REALITY_SNI}" || die 'Invalid REALITY_SNI in state.'
    validate_fqdn "${XHTTP_SNI}" || die 'Invalid XHTTP_SNI in state.'
    [[ "${REALITY_SNI}" != "${XHTTP_SNI}" ]] || die 'The two domains must be different.'
    validate_ipv4 "${EDGE_IPV4}" || die 'Invalid EDGE_IPV4 in state.'
    validate_ipv4 "${PANEL_IPV4}" || die 'Invalid PANEL_IPV4 in state.'
    validate_port "${NODE_PORT}" || die 'Invalid NODE_PORT in state.'
    case "${NODE_PORT}" in
        443|"${RAW_BACKEND_PORT}"|"${XHTTP_BACKEND_PORT}"|"${CADDY_BACKEND_PORT}"|\
        "${HYSTERIA_MASQ_PORT}"|"${HAPROXY_STATS_PORT}"|"${RAW_TEST_PORT}"|\
        "${RAW_FRAGMENT_TEST_PORT}"|"${XHTTP_TEST_PORT}"|"${HYSTERIA_TEST_PORT}")
            die 'NODE_PORT in state conflicts with an edge or verification listener.' ;;
    esac
    [[ "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
        die 'Invalid ACME_EMAIL in state.'
    [[ "${NODE_SLUG}" =~ ^[a-z0-9][a-z0-9-]{1,31}$ ]] || die 'Invalid NODE_SLUG in state.'
    [[ "${XHTTP_PATH}" =~ ^/api/v1/[0-9a-f]{48}/$ ]] || die 'Invalid XHTTP_PATH in state.'
    [[ "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die 'Invalid REALITY_SHORT_ID in state.'
    [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] || die 'Missing REALITY material in state.'
    [[ "${ENABLE_HYSTERIA}" =~ ^[01]$ ]] || die 'Invalid ENABLE_HYSTERIA in state.'
    [[ "${ENABLE_RAW_FRAGMENT}" =~ ^[01]$ ]] || die 'Invalid ENABLE_RAW_FRAGMENT in state.'
    [[ "${BLOCK_CLIENT_QUIC}" =~ ^[01]$ ]] || die 'Invalid BLOCK_CLIENT_QUIC in state.'
    [[ "${APPLY_TUNING}" =~ ^[01]$ ]] || die 'Invalid APPLY_TUNING in state.'
    validate_fingerprint "${CLIENT_FINGERPRINT}" || die 'Invalid CLIENT_FINGERPRINT in state.'
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        [[ "${HYSTERIA_CERT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid Hysteria certificate pin in state.'
        validate_hysteria_material
    fi
}

show_configuration_summary() {
    local transports='RAW/REALITY + TLS/XHTTP'
    local fragment_status='disabled' quic_status='disabled' tuning_status='disabled'
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || transports+=' + Hysteria2'
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || fragment_status='enabled'
    [[ "${BLOCK_CLIENT_QUIC}" != 1 ]] || quic_status='enabled'
    [[ "${APPLY_TUNING}" != 1 ]] || tuning_status='enabled'
    ui_section 'Configuration summary' 'safe values only; generated keys and paths stay hidden'
    ui_kv 'Node name' "${NODE_SLUG}"
    ui_kv 'Install directory' "${INSTALL_DIR}"
    ui_kv 'Edge IPv4' "${EDGE_IPV4}"
    ui_kv 'Panel egress IPv4' "${PANEL_IPV4}"
    ui_kv 'Node API' "${NODE_PORT}/tcp (Panel allowlist only)"
    ui_kv 'REALITY SNI' "${REALITY_SNI}"
    ui_kv 'XHTTP / cover SNI' "${XHTTP_SNI}"
    ui_kv 'Transports' "${transports}"
    ui_kv 'Client fingerprint' "${CLIENT_FINGERPRINT}"
    ui_kv 'Fragment A/B Host' "${fragment_status}"
    ui_kv 'Inner QUIC block' "${quic_status}"
    ui_kv 'Reversible tuning' "${tuning_status}"
    confirm_continue
}

init_stage() {
    local detected_ip default_node_name
    announce_stage init
    require_root
    set_paths
    need_commands
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
        validate_loaded_state
        pull_images
        render_validate_transaction
        log "Existing protected state and every generated artifact were rebuilt and validated."
        return 0
    fi

    detected_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1)"
    REALITY_SNI="${RW_REALITY_SNI:-}"
    XHTTP_SNI="${RW_XHTTP_SNI:-}"
    EDGE_IPV4="${RW_EDGE_IPV4:-}"
    PANEL_IPV4="${RW_PANEL_IPV4:-}"
    ACME_EMAIL="${RW_ACME_EMAIL:-}"
    NODE_PORT="${RW_NODE_PORT:-}"
    NODE_SLUG="${RW_NODE_NAME:-}"
    ENABLE_HYSTERIA="${RW_ENABLE_HYSTERIA:-}"
    ENABLE_RAW_FRAGMENT="${RW_ENABLE_RAW_FRAGMENT:-}"
    BLOCK_CLIENT_QUIC="${RW_BLOCK_CLIENT_QUIC:-}"
    APPLY_TUNING="${RW_APPLY_TUNING:-}"
    CLIENT_FINGERPRINT="${RW_CLIENT_FINGERPRINT:-firefox}"
    prompt_value REALITY_SNI 'Self-SNI domain for RAW REALITY'
    prompt_value XHTTP_SNI 'Second domain for TLS/XHTTP'
    prompt_value EDGE_IPV4 'Public IPv4 of this Node' "${detected_ip}"
    prompt_value PANEL_IPV4 'Observed public/NAT egress IPv4 of Remnawave Panel'
    prompt_value ACME_EMAIL 'Email for ACME certificate notices'
    prompt_value NODE_PORT 'Node API port (Panel control plane only)' '3334'
    default_node_name="$(hostname -s 2>/dev/null | tr '[:upper:]_' '[:lower:]-' | \
        tr -cd 'a-z0-9-' | cut -c1-24)"
    default_node_name="${default_node_name:-edge-node}"
    prompt_value NODE_SLUG 'Short Node name (for example jade-noda)' "${default_node_name}"
    prompt_yes_no ENABLE_HYSTERIA \
        'Enable Hysteria2 on UDP/443 as the third transport?' 1
    prompt_yes_no ENABLE_RAW_FRAGMENT \
        'Generate a separate RAW client-fragment A/B Host?' 1
    prompt_yes_no BLOCK_CLIENT_QUIC \
        'Block inner client QUIC/UDP443 for the stable RU profile?' 1
    prompt_yes_no APPLY_TUNING \
        'Apply reversible BBR/queue/UDP tuning during the Node stage?' 1
    REALITY_SNI="${REALITY_SNI,,}"
    XHTTP_SNI="${XHTTP_SNI,,}"
    CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT,,}"
    validate_fqdn "${REALITY_SNI}" || die "Invalid domain: ${REALITY_SNI}"
    validate_fqdn "${XHTTP_SNI}" || die "Invalid domain: ${XHTTP_SNI}"
    [[ "${REALITY_SNI}" != "${XHTTP_SNI}" ]] || die 'Use two distinct domain names.'
    validate_ipv4 "${EDGE_IPV4}" || die "Invalid edge IPv4: ${EDGE_IPV4}"
    validate_ipv4 "${PANEL_IPV4}" || die "Invalid Panel IPv4: ${PANEL_IPV4}"
    validate_port "${NODE_PORT}" || die "Invalid Node port: ${NODE_PORT}"
    [[ "${NODE_SLUG}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,31}$ ]] || \
        die 'Node name must be 2-32 ASCII letters, digits or hyphens.'
    [[ "${ENABLE_HYSTERIA}" =~ ^[01]$ ]] || die 'RW_ENABLE_HYSTERIA must be 0 or 1.'
    [[ "${ENABLE_RAW_FRAGMENT}" =~ ^[01]$ ]] || die 'RW_ENABLE_RAW_FRAGMENT must be 0 or 1.'
    [[ "${BLOCK_CLIENT_QUIC}" =~ ^[01]$ ]] || die 'RW_BLOCK_CLIENT_QUIC must be 0 or 1.'
    [[ "${APPLY_TUNING}" =~ ^[01]$ ]] || die 'RW_APPLY_TUNING must be 0 or 1.'
    validate_fingerprint "${CLIENT_FINGERPRINT}" || die 'Invalid RW_CLIENT_FINGERPRINT characters.'
    [[ "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Invalid ACME email.'
    case "${NODE_PORT}" in
        443|"${RAW_BACKEND_PORT}"|"${XHTTP_BACKEND_PORT}"|"${CADDY_BACKEND_PORT}"|\
        "${HYSTERIA_MASQ_PORT}"|"${HAPROXY_STATS_PORT}"|"${RAW_TEST_PORT}"|\
        "${RAW_FRAGMENT_TEST_PORT}"|"${XHTTP_TEST_PORT}"|"${HYSTERIA_TEST_PORT}")
            die "Node port ${NODE_PORT} conflicts with the edge." ;;
    esac

    NODE_SLUG="${NODE_SLUG,,}"
    NODE_CODE="$(printf '%s' "${NODE_SLUG}" | tr '[:lower:]-' '[:upper:]_')"
    NODE_CODE_LOWER="${NODE_SLUG}"
    PROFILE_NAME="RW-EDGE-${NODE_CODE}"
    RAW_TAG="RW_${NODE_CODE}_RAW_REALITY"
    XHTTP_TAG="RW_${NODE_CODE}_XHTTP_TLS"
    HYSTERIA_TAG="RW_${NODE_CODE}_HYSTERIA2"
    NODE_CONTAINER="rw-edge-node-${NODE_CODE_LOWER}"
    HAPROXY_CONTAINER="rw-edge-haproxy-${NODE_CODE_LOWER}"
    CADDY_CONTAINER="rw-edge-caddy-${NODE_CODE_LOWER}"
    COMPOSE_PROJECT="rw-edge-${NODE_CODE_LOWER}"

    show_configuration_summary
    install -d -m 0700 "${PRIVATE_DIR}"
    pull_images
    generate_material
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then generate_hysteria_certificate; fi
    render_validate_transaction
    write_state
    success "Initialization complete in ${INSTALL_DIR}."
    ui_file 'Next: create the Config Profile and Node using this guide' \
        "${PRIVATE_DIR}/PANEL-STAGE-1.txt"
}

panel_stage() {
    announce_stage panel
    require_root
    load_state
    validate_loaded_state
    render_happ_rules
    render_panel_stage_one
    render_panel_stage_two
    ui_file 'Panel stage 1 guide' "${PRIVATE_DIR}/PANEL-STAGE-1.txt"
    if [[ -f "${PRIVATE_DIR}/PANEL-STAGE-2.txt" ]]; then
        ui_file 'Panel stage 2 guide' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
    fi
    printf '\n'
    sed -n '1,240p' "${PRIVATE_DIR}/PANEL-STAGE-1.txt"
    if [[ -f "${PRIVATE_DIR}/PANEL-STAGE-2.txt" ]]; then
        printf '\n'
        sed -n '1,240p' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
    fi
}

save_node_secret() {
    local secret="${RW_NODE_SECRET_KEY:-}"
    if [[ -z "${secret}" ]]; then
        if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then
            die 'RW_NODE_SECRET_KEY is required for the node stage.'
        fi
        printf '%b?%b Paste the SECRET_KEY issued by this Node object in Panel: ' \
            "${UI_CYAN}${UI_BOLD}" "${UI_RESET}"
        IFS= read -r -s secret || die 'SECRET_KEY input was interrupted.'
        printf '\n'
    fi
    [[ ${#secret} -ge 32 ]] || die 'SECRET_KEY is unexpectedly short.'
    [[ "${secret}" != *[[:space:]]* ]] || die 'SECRET_KEY must not contain whitespace.'
    [[ "${secret}" != '__PANEL_SECRET_REQUIRED__' ]] || die 'Replace the placeholder SECRET_KEY.'
    write_node_env "${secret}"
    unset secret RW_NODE_SECRET_KEY
}

panel_session_present() {
    # $3 и $4, а не $4 и $5: фильтр `state established` убирает колонку State,
    # и всё смещается на одну влево. Со старой раскладкой $5 не существовал
    # вовсе, условие не выполнялось никогда, и функция отвечала «панели нет»
    # даже при живых соединениях — отсюда ожидание 180 секунд и падение.
    ss -H -tn state established | awk -v p=":${NODE_PORT}" -v ip="${PANEL_IPV4}" '
        substr($3, length($3) - length(p) + 1) == p &&
        (index($4, ip ":") == 1 || index($4, "[::ffff:" ip "]:") == 1) {found=1}
        END {exit !found}
    '
}

wait_for_node_ready() {
    local attempt
    for attempt in $(seq 1 90); do
        if port_is_listening "${NODE_PORT}" && \
           port_is_listening "${RAW_BACKEND_PORT}" && \
           port_is_listening "${XHTTP_BACKEND_PORT}" && \
           { [[ "${ENABLE_HYSTERIA}" != 1 ]] || udp_port_is_listening 443; } && \
           panel_session_present; then
            log 'Node API, all selected Xray transports and an established Panel session are ready.'
            return 0
        fi
        sleep 2
    done
    docker logs --tail 40 "${NODE_CONTAINER}" 2>&1 | sed -E 's/(SECRET_KEY=)[^ ]+/\1[REDACTED]/g' >&2 || true
    die 'Node did not become Panel-managed within 180 seconds. Recheck Panel address/port/profile/inbounds and provider firewall.'
}

check_negative_mtls() {
    local code tls_probe
    code="$(curl --silent --show-error --connect-timeout 5 --max-time 8 \
        --insecure --output /dev/null --write-out '%{http_code}' \
        "https://127.0.0.1:${NODE_PORT}/" 2>/dev/null || true)"
    [[ "${code}" == 000 || -z "${code}" ]] || \
        die "Node API unexpectedly answered unauthenticated HTTPS with HTTP ${code}."
    tls_probe="$(timeout 8 openssl s_client -connect "127.0.0.1:${NODE_PORT}" \
        -tls1_3 -brief </dev/null 2>&1 || true)"
    grep -Eqi 'tlsv13 alert certificate required|alert number 116' <<<"${tls_probe}" || \
        die 'Node API did not prove mandatory client-certificate rejection over TLS 1.3.'
}

apply_tuning_loaded() {
    local key snapshot="${PRIVATE_DIR}/sysctl-before.txt" snapshot_tmp default_interface live_qdisc
    local sysctl_target='/etc/sysctl.d/99-remnawave-edge.conf'
    local module_target='/etc/modules-load.d/remnawave-edge.conf'
    local keys=(
      net.core.default_qdisc net.ipv4.tcp_congestion_control
      net.ipv4.tcp_mtu_probing net.core.somaxconn
      net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog
      net.core.rmem_max net.core.wmem_max
      net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
    )
    if [[ ! -f "${snapshot}" ]]; then
        snapshot_tmp="$(mktemp "${PRIVATE_DIR}/.sysctl-before.XXXXXX")"
        for key in "${keys[@]}"; do
            printf '%s=%s\n' "${key}" "$(sysctl -n "${key}")" >>"${snapshot_tmp}"
        done
        chmod 0600 "${snapshot_tmp}"
        mv -f -- "${snapshot_tmp}" "${snapshot}"
        [[ ! -f "${sysctl_target}" ]] || cp -a "${sysctl_target}" "${PRIVATE_DIR}/sysctl-file.before"
        [[ ! -f "${module_target}" ]] || cp -a "${module_target}" "${PRIVATE_DIR}/modules-file.before"
        STAGE_TUNING_WAS_NEW=1
    fi
    modprobe tcp_bbr
    install -m 0644 "${INSTALL_DIR}/99-remnawave-edge.conf" "${sysctl_target}"
    printf 'tcp_bbr\n' >"${module_target}"
    chmod 0644 "${module_target}"
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || die 'BBR did not become active.'
    default_interface="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
    live_qdisc="$(tc qdisc show dev "${default_interface}" 2>/dev/null | awk 'NR == 1 {print $2}')"
    if [[ "${live_qdisc}" != fq ]]; then
        warn "default_qdisc=fq is saved for future interfaces, but ${default_interface:-default interface} currently uses ${live_qdisc:-unknown}; no disruptive live qdisc replacement was made."
    fi
    log 'Applied reversible BBR, MTU probing, backlog and UDP socket-buffer baseline.'
}

tune_stage() {
    announce_stage tune
    require_root
    load_state
    validate_loaded_state
    render_tuning
    STAGE_UFW_SNAPSHOT=''
    STAGE_TUNING_WAS_NEW=0
    STAGE_STOP_NODE=0
    STAGE_STOP_HAPROXY=0
    STAGE_STOP_CADDY=0
    trap rollback_failed_stage EXIT INT TERM
    apply_tuning_loaded
    commit_stage
}

restore_tuning_loaded() {
    local line key value snapshot sysctl_target module_target
    snapshot="${PRIVATE_DIR}/sysctl-before.txt"
    sysctl_target='/etc/sysctl.d/99-remnawave-edge.conf'
    module_target='/etc/modules-load.d/remnawave-edge.conf'
    [[ -f "${snapshot}" ]] || die 'No pre-tuning snapshot exists; nothing can be restored safely.'
    if [[ -f "${PRIVATE_DIR}/sysctl-file.before" ]]; then
        install -m 0644 "${PRIVATE_DIR}/sysctl-file.before" "${sysctl_target}"
    else
        rm -f -- "${sysctl_target}"
    fi
    if [[ -f "${PRIVATE_DIR}/modules-file.before" ]]; then
        install -m 0644 "${PRIVATE_DIR}/modules-file.before" "${module_target}"
    else
        rm -f -- "${module_target}"
    fi
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        sysctl -w "${key}=${value}" >/dev/null
    done <"${snapshot}"
    log 'Restored the exact sysctl values recorded before tuning.'
}

untune_stage() {
    announce_stage untune
    require_root
    load_state
    restore_tuning_loaded
}

node_stage() {
    local node_was_running=0
    announce_stage node
    require_root
    need_commands
    load_state
    validate_loaded_state
    pull_images
    render_validate_transaction
    assert_port_free_or_owned "${NODE_PORT}" "${NODE_CONTAINER}"
    assert_port_free_or_owned "${RAW_BACKEND_PORT}" "${NODE_CONTAINER}"
    assert_port_free_or_owned "${XHTTP_BACKEND_PORT}" "${NODE_CONTAINER}"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]] && udp_port_is_listening 443 && \
       ! container_is_running "${NODE_CONTAINER}"; then
        die 'UDP/443 is occupied by another service.'
    fi
    container_is_running "${NODE_CONTAINER}" && node_was_running=1
    if [[ "${node_was_running}" == 1 ]]; then
        port_is_listening "${NODE_PORT}" || die 'Existing managed Node has no API listener.'
        port_is_listening "${RAW_BACKEND_PORT}" || die 'Existing managed Node has no RAW listener.'
        port_is_listening "${XHTTP_BACKEND_PORT}" || die 'Existing managed Node has no XHTTP listener.'
        panel_session_present || die 'Existing managed Node has no established Panel session.'
        check_negative_mtls
        check_runtime_path
        log 'Existing managed Node passed control-plane and runtime-contract checks; it was not recreated.'
        return 0
    fi
    arm_stage_rollback node
    apply_firewall
    if [[ "${APPLY_TUNING}" == 1 ]]; then apply_tuning_loaded; fi
    save_node_secret
    [[ "${node_was_running}" == 1 ]] || STAGE_STOP_NODE=1
    docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" up -d
    wait_for_node_ready
    check_negative_mtls
    commit_stage
    success 'Node stage passed. Create the canary squad/user and all enabled physical Hosts in Panel.'
    ui_file 'Exact Host fields and next checkpoint' "${PRIVATE_DIR}/PANEL-STAGE-1.txt"
}

template_stage() {
    local uuid
    local -a extra normalized_extra
    local -A seen_extra=()
    announce_stage template
    require_root
    load_state
    validate_loaded_state
    RAW_HOST_UUID="${RW_RAW_HOST_UUID:-${RAW_HOST_UUID:-}}"
    RAW_FRAGMENT_HOST_UUID="${RW_RAW_FRAGMENT_HOST_UUID:-${RAW_FRAGMENT_HOST_UUID:-}}"
    XHTTP_HOST_UUID="${RW_XHTTP_HOST_UUID:-${XHTTP_HOST_UUID:-}}"
    HYSTERIA_HOST_UUID="${RW_HYSTERIA_HOST_UUID:-${HYSTERIA_HOST_UUID:-}}"
    EXTRA_HOST_UUIDS="${RW_EXTRA_HOST_UUIDS:-${EXTRA_HOST_UUIDS:-}}"
    prompt_value RAW_HOST_UUID 'RAW physical Host UUID'
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        prompt_value RAW_FRAGMENT_HOST_UUID 'RAW Fragment physical Host UUID'
    fi
    prompt_value XHTTP_HOST_UUID 'XHTTP physical Host UUID'
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        prompt_value HYSTERIA_HOST_UUID 'Hysteria2 physical Host UUID'
    fi
    validate_uuid "${RAW_HOST_UUID}" || die 'Invalid RAW Host UUID.'
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || validate_uuid "${RAW_FRAGMENT_HOST_UUID}" || \
        die 'Invalid RAW Fragment Host UUID.'
    validate_uuid "${XHTTP_HOST_UUID}" || die 'Invalid XHTTP Host UUID.'
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || validate_uuid "${HYSTERIA_HOST_UUID}" || \
        die 'Invalid Hysteria2 Host UUID.'
    RAW_HOST_UUID="${RAW_HOST_UUID,,}"
    RAW_FRAGMENT_HOST_UUID="${RAW_FRAGMENT_HOST_UUID,,}"
    XHTTP_HOST_UUID="${XHTTP_HOST_UUID,,}"
    HYSTERIA_HOST_UUID="${HYSTERIA_HOST_UUID,,}"
    [[ "${RAW_HOST_UUID}" != "${XHTTP_HOST_UUID}" ]] || die 'Physical Host UUIDs must be different.'
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        [[ "${RAW_FRAGMENT_HOST_UUID}" != "${RAW_HOST_UUID}" && \
           "${RAW_FRAGMENT_HOST_UUID}" != "${XHTTP_HOST_UUID}" ]] || \
            die 'RAW Fragment Host UUID duplicates another physical Host.'
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        [[ "${HYSTERIA_HOST_UUID}" != "${RAW_HOST_UUID}" && \
           "${HYSTERIA_HOST_UUID}" != "${RAW_FRAGMENT_HOST_UUID:-}" && \
           "${HYSTERIA_HOST_UUID}" != "${XHTTP_HOST_UUID}" ]] || \
            die 'Hysteria2 Host UUID duplicates another physical Host.'
    fi
    if [[ -n "${EXTRA_HOST_UUIDS}" ]]; then
        IFS=',' read -r -a extra <<<"${EXTRA_HOST_UUIDS}"
        for uuid in "${extra[@]}"; do
            uuid="${uuid//[[:space:]]/}"
            validate_uuid "${uuid}" || die "Invalid extra Host UUID: ${uuid}"
            uuid="${uuid,,}"
            [[ "${uuid,,}" != "${RAW_HOST_UUID}" && "${uuid,,}" != "${XHTTP_HOST_UUID}" && \
               "${uuid,,}" != "${RAW_FRAGMENT_HOST_UUID:-}" && \
               "${uuid,,}" != "${HYSTERIA_HOST_UUID:-}" ]] || \
                die 'Extra Host UUID duplicates one of this node physical Hosts.'
            [[ -z "${seen_extra[${uuid}]:-}" ]] || die "Duplicate extra Host UUID: ${uuid}"
            seen_extra["${uuid}"]=1
            normalized_extra+=("${uuid}")
        done
        EXTRA_HOST_UUIDS="$(IFS=,; printf '%s' "${normalized_extra[*]}")"
    fi
    render_happ_rules
    render_auto_template
    render_panel_stage_two
    jq empty "${PRIVATE_DIR}/xray-json-auto.ready.json"
    validate_auto_template_model "${PRIVATE_DIR}/xray-json-auto.ready.json"
    write_state
    success 'XRAY_JSON AUTO template rendered and validated.'
    ui_file 'Ready template' "${PRIVATE_DIR}/xray-json-auto.ready.json"
    ui_file 'Exact Panel steps' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
    if [[ "${SHOW_VALUES}" == 1 ]]; then
        sed -n '1,240p' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
    fi
}

wait_for_public_tls() {
    local domain="$1" attempt
    for attempt in $(seq 1 90); do
        if curl --silent --show-error --fail --noproxy '*' --max-time 10 \
            --resolve "${domain}:443:${EDGE_IPV4}" \
            "https://${domain}/health.txt" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

edge_stage() {
    local haproxy_was_running=0 caddy_was_running=0
    announce_stage edge
    require_root
    need_commands
    load_state
    validate_loaded_state
    pull_images
    [[ -f "${PRIVATE_DIR}/xray-json-auto.ready.json" ]] || \
        warn 'AUTO template is not rendered yet; edge transport can start, but run template before client testing.'
    check_dns
    validate_artifacts
    container_is_running "${NODE_CONTAINER}" || die 'Managed Node is not running. Run the node stage first.'
    port_is_listening "${RAW_BACKEND_PORT}" || die 'RAW backend is not listening.'
    port_is_listening "${XHTTP_BACKEND_PORT}" || die 'XHTTP backend is not listening.'
    panel_session_present || die 'No established Panel session to the Node API.'
    assert_port_free_or_owned 443 "${HAPROXY_CONTAINER}"
    assert_port_free_or_owned "${CADDY_BACKEND_PORT}" "${CADDY_CONTAINER}"
    assert_port_free_or_owned "${HYSTERIA_MASQ_PORT}" "${CADDY_CONTAINER}"
    assert_port_free_or_owned "${HAPROXY_STATS_PORT}" "${HAPROXY_CONTAINER}"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        udp_port_is_listening 443 || die 'Selected Hysteria2 UDP/443 is not listening.'
    elif udp_port_is_listening 443; then
        die 'UDP/443 is occupied although Hysteria2 is disabled.'
    fi
    container_is_running "${HAPROXY_CONTAINER}" && haproxy_was_running=1
    container_is_running "${CADDY_CONTAINER}" && caddy_was_running=1
    if [[ "${haproxy_was_running}" == 1 && "${caddy_was_running}" == 1 ]]; then
        log 'Existing edge containers found; verifying in place instead of silently recreating production.'
        verify_stage
        return 0
    fi
    [[ "${haproxy_was_running}" == "${caddy_was_running}" ]] || \
        die 'Only one edge container is running. Run verify/status and resolve the partial state before retrying.'
    arm_stage_rollback edge
    apply_firewall

    log 'Starting HAProxy first so TLS-ALPN validation has a public TCP/443 path...'
    [[ "${haproxy_was_running}" == 1 ]] || STAGE_STOP_HAPROXY=1
    docker compose --env-file "${PRIVATE_DIR}/edge.env" \
        -f "${INSTALL_DIR}/docker-compose.edge.yml" up -d haproxy
    port_is_listening 443 || die 'HAProxy did not bind public TCP/443.'
    log 'Starting Caddy and obtaining trusted certificates...'
    [[ "${caddy_was_running}" == 1 ]] || STAGE_STOP_CADDY=1
    docker compose --env-file "${PRIVATE_DIR}/edge.env" \
        -f "${INSTALL_DIR}/docker-compose.edge.yml" up -d caddy

    wait_for_public_tls "${REALITY_SNI}" || {
        docker logs --tail 80 "${CADDY_CONTAINER}" >&2 || true
        die "Trusted HTTPS did not become ready for ${REALITY_SNI}."
    }
    wait_for_public_tls "${XHTTP_SNI}" || {
        docker logs --tail 80 "${CADDY_CONTAINER}" >&2 || true
        die "Trusted HTTPS did not become ready for ${XHTTP_SNI}."
    }
    verify_stage
    commit_stage
}

check_container_health() {
    local container="$1" expected_image="$2" state restarts actual_image
    state="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || true)"
    restarts="$(docker inspect -f '{{.RestartCount}}' "${container}" 2>/dev/null || true)"
    [[ "${state}" == running ]] || die "Container ${container} is not running (${state:-absent})."
    [[ "${restarts}" =~ ^[0-9]+$ ]] || die "Cannot read restart count for ${container}."
    ((restarts <= 2)) || warn "Container ${container} has ${restarts} lifetime restarts; investigate logs, but current health checks continue."
    actual_image="$(docker inspect -f '{{.Config.Image}}' "${container}")"
    [[ "${actual_image}" == "${expected_image}" ]] || die "Container ${container} is not using the pinned image."
}

check_https_cover() {
    local domain="$1" headers code cert_file verify_output
    headers="$(curl --silent --show-error --fail --noproxy '*' --http2 \
        --resolve "${domain}:443:${EDGE_IPV4}" -D - -o /dev/null "https://${domain}/")"
    grep -Eq '^HTTP/2 200' <<<"${headers}" || die "${domain} did not return HTTP/2 200."
    ! grep -Eqi '^alt-svc:' <<<"${headers}" || die "${domain} advertises unsupported HTTP/3/Alt-Svc."
    ! grep -Eqi '^server:' <<<"${headers}" || die "${domain} exposes a Server header."
    for header in content-security-policy strict-transport-security x-content-type-options x-frame-options; do
        grep -Eqi "^${header}:" <<<"${headers}" || die "${domain} is missing ${header}."
    done
    code="$(curl --silent --show-error --noproxy '*' \
        --resolve "${domain}:443:${EDGE_IPV4}" -o /dev/null -w '%{http_code}' \
        "https://${domain}/route-that-must-not-exist")"
    [[ "${code}" == 404 ]] || die "${domain} fake route returned ${code}, expected 404."

    cert_file="$(mktemp)"
    openssl s_client -connect "${EDGE_IPV4}:443" -servername "${domain}" -showcerts </dev/null 2>/dev/null | \
        openssl x509 -outform PEM >"${cert_file}"
    openssl x509 -in "${cert_file}" -noout -checkhost "${domain}" >/dev/null || {
        rm -f -- "${cert_file}"
        die "Certificate SAN does not cover ${domain}."
    }
    verify_output="$(openssl s_client -connect "${EDGE_IPV4}:443" -servername "${domain}" \
        -verify_hostname "${domain}" -verify_return_error -CApath /etc/ssl/certs \
        </dev/null 2>&1 || true)"
    grep -Fq 'Verify return code: 0 (ok)' <<<"${verify_output}" || {
        rm -f -- "${cert_file}"
        die "Certificate trust verification failed for ${domain}."
    }
    rm -f -- "${cert_file}"
}

check_runtime_path() (
    local temp_dir dump
    temp_dir="$(mktemp -d)"
    dump="${temp_dir}/runtime.json"
    runtime_cleanup() {
        if [[ -f "${dump}" ]]; then truncate -s 0 "${dump}"; fi
        find "${temp_dir}" -depth -delete 2>/dev/null || true
    }
    trap runtime_cleanup EXIT
    install -m 0600 /dev/null "${dump}"
    docker exec "${NODE_CONTAINER}" cli --dump-config-raw >"${dump}" 2>/dev/null || \
        die 'Could not obtain protected Node runtime config.'
    jq -e --arg tag "${XHTTP_TAG}" --arg path "${XHTTP_PATH}" '
      ([.inbounds[] | select(.tag == $tag) |
        {path: .streamSettings.xhttpSettings.path, mode: .streamSettings.xhttpSettings.mode}] |
       unique) == [{path: $path, mode: "packet-up"}]
    ' "${dump}" >/dev/null || \
        die 'Live Node XHTTP path or packet-up mode differs from protected edge state.'
)

verify_stage() {
    local exact_code decoy_code loopback_port
    announce_stage verify
    require_root
    need_commands
    load_state
    validate_loaded_state
    check_dns
    check_container_health "${NODE_CONTAINER}" "${NODE_IMAGE}"
    check_container_health "${HAPROXY_CONTAINER}" "${HAPROXY_IMAGE}"
    check_container_health "${CADDY_CONTAINER}" "${CADDY_IMAGE}"
    docker inspect "${NODE_CONTAINER}" | jq -e '
        ((.[0].HostConfig.CapAdd // []) | map(sub("^CAP_"; "")) | index("NET_ADMIN") | not) and
        ((.[0].HostConfig.CapDrop // []) | map(sub("^CAP_"; "")) | index("NET_ADMIN") != null)
    ' >/dev/null || die 'Managed Node unexpectedly has NET_ADMIN; fixed RemnaNode nft table names make that unsafe.'
    port_is_listening 443 || die 'Public TCP/443 is not listening.'
    port_is_listening "${NODE_PORT}" || die 'Node API is not listening.'
    port_is_listening "${RAW_BACKEND_PORT}" || die 'RAW backend is not listening.'
    port_is_listening "${XHTTP_BACKEND_PORT}" || die 'XHTTP backend is not listening.'
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        udp_port_is_listening 443 || die 'Hysteria2 UDP/443 is not listening.'
        udp_port_owned_by_container 443 "${NODE_CONTAINER}" || \
            die 'UDP/443 is not owned by the managed Node container.'
    else
        ! udp_port_is_listening 443 || die 'UDP/443 unexpectedly listens.'
    fi
    port_is_listening "${CADDY_BACKEND_PORT}" || die 'Caddy loopback backend is not listening.'
    port_is_listening "${HYSTERIA_MASQ_PORT}" || die 'Caddy Hysteria masquerade origin is not listening.'
    port_is_listening "${HAPROXY_STATS_PORT}" || die 'HAProxy loopback stats is not listening.'
    for loopback_port in "${RAW_BACKEND_PORT}" "${XHTTP_BACKEND_PORT}" "${CADDY_BACKEND_PORT}" \
        "${HYSTERIA_MASQ_PORT}" "${HAPROXY_STATS_PORT}"; do
        port_is_loopback_only "${loopback_port}" || die "Backend ${loopback_port} is not loopback-only."
    done
    [[ -z "$(ss -H -ltn 'sport = :80')" ]] || die 'TCP/80 unexpectedly listens; this design uses TLS-ALPN on TCP/443 only.'
    panel_session_present || die 'No established Panel session to Node API.'
    check_negative_mtls
    check_https_cover "${REALITY_SNI}"
    check_https_cover "${XHTTP_SNI}"

    exact_code="$(curl --silent --show-error --noproxy '*' --http2 \
        --resolve "${XHTTP_SNI}:443:${EDGE_IPV4}" -o /dev/null -w '%{http_code}' \
        "https://${XHTTP_SNI}${XHTTP_PATH}" 2>/dev/null || true)"
    [[ "${exact_code}" =~ ^[234][0-9][0-9]$ && "${exact_code}" != 404 ]] || \
        die 'Exact XHTTP route did not reach Xray.'
    decoy_code="$(curl --silent --show-error --noproxy '*' --http2 \
        --resolve "${XHTTP_SNI}:443:${EDGE_IPV4}" -o /dev/null -w '%{http_code}' \
        "https://${XHTTP_SNI}/api/v1/not-the-transport/" 2>/dev/null || true)"
    [[ "${decoy_code}" == 404 ]] || die "Decoy XHTTP route returned ${decoy_code}, expected 404."
    check_runtime_path
    log 'PASS: DNS, mTLS control plane, selected listeners, trusted HTTP/2 covers and XHTTP routing.'
}

render_auth_clients() {
    local runtime="$1" raw_config="$2" xhttp_config="$3" hysteria_config="$4"
    local raw_id xhttp_id hysteria_auth short_id
    raw_id="$(jq -r --arg tag "${RAW_TAG}" '.inbounds[] | select(.tag == $tag) | .settings.clients[0].id // empty' "${runtime}")"
    xhttp_id="$(jq -r --arg tag "${XHTTP_TAG}" '.inbounds[] | select(.tag == $tag) | .settings.clients[0].id // empty' "${runtime}")"
    short_id="$(jq -r --arg tag "${RAW_TAG}" '.inbounds[] | select(.tag == $tag) | .streamSettings.realitySettings.shortIds[0] // empty' "${runtime}")"
    validate_uuid "${raw_id}" || die 'No active user credential was injected into RAW inbound.'
    validate_uuid "${xhttp_id}" || die 'No active user credential was injected into XHTTP inbound.'
    [[ "${short_id}" =~ ^[0-9a-fA-F]{16}$ ]] || die 'Live REALITY shortId is invalid.'

    jq -n --arg address "${EDGE_IPV4}" --arg id "${raw_id}" \
        --arg server_name "${REALITY_SNI}" --arg public_key "${REALITY_PUBLIC_KEY}" \
        --arg short_id "${short_id}" --arg fingerprint "${CLIENT_FINGERPRINT}" \
        --argjson socks_port "${RAW_TEST_PORT}" '
      {
        log: {loglevel: "warning"},
        inbounds: [{tag: "socks-in", listen: "127.0.0.1", port: $socks_port, protocol: "socks", settings: {auth: "noauth", udp: true}}],
        outbounds: [{
          tag: "proxy", protocol: "vless",
          settings: {vnext: [{address: $address, port: 443, users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]}]},
          streamSettings: {network: "raw", security: "reality", realitySettings: {serverName: $server_name, fingerprint: $fingerprint, publicKey: $public_key, shortId: $short_id, spiderX: "/"}}
        }]
      }
    ' >"${raw_config}"

    jq -n --arg address "${EDGE_IPV4}" --arg id "${xhttp_id}" \
        --arg server_name "${XHTTP_SNI}" --arg path "${XHTTP_PATH}" \
        --arg fingerprint "${CLIENT_FINGERPRINT}" \
        --argjson socks_port "${XHTTP_TEST_PORT}" '
      {
        log: {loglevel: "warning"},
        inbounds: [{tag: "socks-in", listen: "127.0.0.1", port: $socks_port, protocol: "socks", settings: {auth: "noauth", udp: true}}],
        outbounds: [{
          tag: "proxy", protocol: "vless",
          settings: {vnext: [{address: $address, port: 443, users: [{id: $id, encryption: "none"}]}]},
          streamSettings: {network: "xhttp", security: "tls", tlsSettings: {serverName: $server_name, fingerprint: $fingerprint, alpn: ["h2"]}, xhttpSettings: {host: $server_name, path: $path, mode: "packet-up"}}
        }]
      }
    ' >"${xhttp_config}"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        hysteria_auth="$(jq -r --arg tag "${HYSTERIA_TAG}" '
          .inbounds[] | select(.tag == $tag) | .settings.clients[0].auth // empty
        ' "${runtime}")"
        validate_uuid "${hysteria_auth}" || die 'No active user credential was injected into Hysteria2 inbound.'
        jq -n --arg address "${EDGE_IPV4}" --arg auth "${hysteria_auth}" \
            --arg server_name "${XHTTP_SNI}" --arg pin "${HYSTERIA_CERT_SHA256}" \
            --arg fingerprint "${CLIENT_FINGERPRINT}" \
            --argjson socks_port "${HYSTERIA_TEST_PORT}" '
          {
            log: {loglevel: "warning"},
            inbounds: [{tag: "socks-in", listen: "127.0.0.1", port: $socks_port,
              protocol: "socks", settings: {auth: "noauth", udp: true}}],
            outbounds: [{
              tag: "proxy", protocol: "hysteria",
              settings: {address: $address, port: 443, version: 2},
              streamSettings: {
                network: "hysteria", security: "tls",
                tlsSettings: {
                  serverName: $server_name, fingerprint: $fingerprint, alpn: ["h3"],
                  pinnedPeerCertSha256: $pin
                },
                hysteriaSettings: {version: 2, auth: $auth}
              }
            }]
          }
        ' >"${hysteria_config}"
    fi
    chmod 0600 "${raw_config}" "${xhttp_config}"
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || chmod 0600 "${hysteria_config}"
}

validate_client_config() {
    local config="$1"
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
        --security-opt no-new-privileges:true \
        -v "${config}:/etc/xray/client.json:ro" \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -test -config /etc/xray/client.json >/dev/null
}

run_transport_test() {
    local name="$1" container="$2" port="$3" config="$4" attempt code
    docker run --detach --rm --pull never --name "${container}" \
        --network host --cap-drop ALL --read-only \
        --security-opt no-new-privileges:true --pids-limit 128 \
        --memory 256m --cpus 0.25 \
        -v "${config}:/etc/xray/client.json:ro" \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -config /etc/xray/client.json >/dev/null
    for ((attempt=1; attempt<=40; attempt++)); do
        port_is_listening "${port}" && break
        sleep 0.25
    done
    port_is_listening "${port}" || die "${name} test client did not start."
    code="$(curl --silent --show-error --max-time 20 \
        --socks5-hostname "127.0.0.1:${port}" --output /dev/null \
        --write-out '%{http_code}' 'https://8.8.8.8/generate_204' 2>/dev/null || true)"
    [[ "${code}" == 204 ]] || die "${name} authenticated probe returned ${code:-no-response}."
    log "PASS: ${name} authenticated public-443 tunnel reached external HTTPS."
    docker stop --time 2 "${container}" >/dev/null
}

verify_auth_stage() {
    announce_stage verify-auth
    local temp_dir runtime raw_config raw_fragment_config xhttp_config hysteria_config
    local raw_test_container raw_fragment_test_container xhttp_test_container hysteria_test_container
    require_root
    need_commands
    load_state
    validate_loaded_state
    check_container_health "${NODE_CONTAINER}" "${NODE_IMAGE}"
    check_container_health "${HAPROXY_CONTAINER}" "${HAPROXY_IMAGE}"
    check_container_health "${CADDY_CONTAINER}" "${CADDY_IMAGE}"
    for port in "${RAW_TEST_PORT}" "${RAW_FRAGMENT_TEST_PORT}" "${XHTTP_TEST_PORT}" "${HYSTERIA_TEST_PORT}"; do
        port_is_listening "${port}" && die "Temporary test port ${port} is occupied."
    done
    raw_test_container="rw-edge-test-raw-${NODE_CODE_LOWER}"
    raw_fragment_test_container="rw-edge-test-raw-fragment-${NODE_CODE_LOWER}"
    xhttp_test_container="rw-edge-test-xhttp-${NODE_CODE_LOWER}"
    hysteria_test_container="rw-edge-test-hy2-${NODE_CODE_LOWER}"
    docker inspect "${raw_test_container}" >/dev/null 2>&1 && die "Stale test container exists: ${raw_test_container}"
    docker inspect "${raw_fragment_test_container}" >/dev/null 2>&1 && die "Stale test container exists: ${raw_fragment_test_container}"
    docker inspect "${xhttp_test_container}" >/dev/null 2>&1 && die "Stale test container exists: ${xhttp_test_container}"
    docker inspect "${hysteria_test_container}" >/dev/null 2>&1 && die "Stale test container exists: ${hysteria_test_container}"

    temp_dir="$(mktemp -d)"
    runtime="${temp_dir}/runtime.json"
    raw_config="${temp_dir}/raw-client.json"
    raw_fragment_config="${temp_dir}/raw-fragment-client.json"
    xhttp_config="${temp_dir}/xhttp-client.json"
    hysteria_config="${temp_dir}/hysteria-client.json"
    auth_cleanup() {
        docker stop --time 2 "${raw_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${raw_fragment_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${xhttp_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${hysteria_test_container}" >/dev/null 2>&1 || true
        if [[ -f "${runtime}" ]]; then truncate -s 0 "${runtime}"; fi
        if [[ -f "${raw_config}" ]]; then truncate -s 0 "${raw_config}"; fi
        if [[ -f "${raw_fragment_config}" ]]; then truncate -s 0 "${raw_fragment_config}"; fi
        if [[ -f "${xhttp_config}" ]]; then truncate -s 0 "${xhttp_config}"; fi
        if [[ -f "${hysteria_config}" ]]; then truncate -s 0 "${hysteria_config}"; fi
        rm -rf -- "${temp_dir}"
    }
    trap auth_cleanup EXIT RETURN
    install -m 0600 /dev/null "${runtime}"
    docker exec "${NODE_CONTAINER}" cli --dump-config-raw >"${runtime}" 2>/dev/null || \
        die 'Could not read protected live Node config.'
    render_auth_clients "${runtime}" "${raw_config}" "${xhttp_config}" "${hysteria_config}"
    validate_client_config "${raw_config}"
    validate_client_config "${xhttp_config}"
    run_transport_test 'RAW REALITY' "${raw_test_container}" "${RAW_TEST_PORT}" "${raw_config}"
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        jq --argjson socks_port "${RAW_FRAGMENT_TEST_PORT}" \
          --slurpfile fm "${INSTALL_DIR}/finalmask-fragment-canary.json" '
          .inbounds[0].port = $socks_port |
          .outbounds[0].streamSettings.finalmask = $fm[0]
        ' "${raw_config}" >"${raw_fragment_config}"
        chmod 0600 "${raw_fragment_config}"
        validate_client_config "${raw_fragment_config}"
        run_transport_test 'RAW REALITY + client fragment' "${raw_fragment_test_container}" \
            "${RAW_FRAGMENT_TEST_PORT}" "${raw_fragment_config}"
    fi
    run_transport_test 'TLS/XHTTP' "${xhttp_test_container}" "${XHTTP_TEST_PORT}" "${xhttp_config}"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        validate_client_config "${hysteria_config}"
        run_transport_test 'Hysteria2' "${hysteria_test_container}" "${HYSTERIA_TEST_PORT}" "${hysteria_config}"
    fi
    success 'PASS: all selected authenticated transports work; credentials were not displayed.'
    trap - EXIT RETURN
    auth_cleanup
}

status_tcp_listener() {
    local label="$1" port="$2" owner="$3"
    if ! port_is_listening "${port}"; then
        ui_status_row check "${label}" 'closed'
    elif container_is_running "${owner}" && tcp_port_owned_by_container "${port}" "${owner}"; then
        ui_status_row ok "${label}" "LISTEN; ${owner}"
    else
        ui_status_row check "${label}" "LISTEN; unexpected owner (expected ${owner})"
    fi
}

status_stage() {
    announce_stage status
    require_root
    load_state
    validate_loaded_state
    local container state restarts reality_answers xhttp_answers
    reality_answers="$(dig +short A "${REALITY_SNI}" | paste -sd, -)"
    xhttp_answers="$(dig +short A "${XHTTP_SNI}" | paste -sd, -)"
    reality_answers="${reality_answers:-unresolved}"
    xhttp_answers="${xhttp_answers:-unresolved}"
    ui_kv 'Install directory' "${INSTALL_DIR}"
    ui_kv 'Versions' "Panel 2.8.1 | Node 2.8.0 | Xray ${EXPECTED_XRAY_VERSION} | wizard ${SCRIPT_VERSION}"
    ui_section 'DNS' 'current public A answers'
    if [[ "${reality_answers}" == "${EDGE_IPV4}" ]]; then
        ui_status_row ok "${REALITY_SNI}" "${reality_answers}"
    else
        ui_status_row check "${REALITY_SNI}" "${reality_answers} (expected ${EDGE_IPV4})"
    fi
    if [[ "${xhttp_answers}" == "${EDGE_IPV4}" ]]; then
        ui_status_row ok "${XHTTP_SNI}" "${xhttp_answers}"
    else
        ui_status_row check "${XHTTP_SNI}" "${xhttp_answers} (expected ${EDGE_IPV4})"
    fi
    ui_section 'Containers' 'state and lifetime restart counter'
    for container in "${NODE_CONTAINER}" "${HAPROXY_CONTAINER}" "${CADDY_CONTAINER}"; do
        if ! state="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null)"; then
            state='absent'
        fi
        if ! restarts="$(docker inspect -f '{{.RestartCount}}' "${container}" 2>/dev/null)"; then
            restarts='-'
        fi
        if [[ "${state}" == running ]]; then
            ui_status_row ok "${container}" "running; restarts ${restarts}"
        else
            ui_status_row check "${container}" "${state}; restarts ${restarts}"
        fi
    done
    ui_section 'Listeners' 'public edge and loopback backends'
    status_tcp_listener 'TCP/443' 443 "${HAPROXY_CONTAINER}"
    status_tcp_listener "TCP/${NODE_PORT}" "${NODE_PORT}" "${NODE_CONTAINER}"
    status_tcp_listener "TCP/${RAW_BACKEND_PORT}" "${RAW_BACKEND_PORT}" "${NODE_CONTAINER}"
    status_tcp_listener "TCP/${XHTTP_BACKEND_PORT}" "${XHTTP_BACKEND_PORT}" "${NODE_CONTAINER}"
    status_tcp_listener "TCP/${CADDY_BACKEND_PORT}" "${CADDY_BACKEND_PORT}" "${CADDY_CONTAINER}"
    status_tcp_listener "TCP/${HYSTERIA_MASQ_PORT}" "${HYSTERIA_MASQ_PORT}" "${CADDY_CONTAINER}"
    status_tcp_listener "TCP/${HAPROXY_STATS_PORT}" "${HAPROXY_STATS_PORT}" "${HAPROXY_CONTAINER}"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]] && udp_port_is_listening 443 && \
       udp_port_owned_by_container 443 "${NODE_CONTAINER}"; then
        ui_status_row ok 'UDP/443' "LISTEN; ${NODE_CONTAINER}"
    elif [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        ui_status_row check 'UDP/443' 'closed; Hysteria2 expected'
    elif udp_port_is_listening 443; then
        ui_status_row check 'UDP/443' 'LISTEN; disabled by configuration'
    else
        ui_status_row ok 'UDP/443' 'closed; disabled by configuration'
    fi
    ui_section 'Control plane' 'Panel -> Node mTLS'
    if panel_session_present; then
        ui_status_row ok 'Panel session' "established from ${PANEL_IPV4}"
    else
        ui_status_row check 'Panel session' 'absent'
    fi
}

rollback_stage() {
    announce_stage rollback
    require_root
    load_state
    warn 'Stopping only containers created by this wizard. DNS, UFW, files and Caddy data remain.'
    if [[ -f "${INSTALL_DIR}/docker-compose.edge.yml" ]]; then
        docker compose --env-file "${PRIVATE_DIR}/edge.env" \
            -f "${INSTALL_DIR}/docker-compose.edge.yml" stop haproxy caddy || true
    fi
    if [[ -f "${INSTALL_DIR}/docker-compose.node.yml" ]]; then
        docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" stop node || true
    fi
    log 'Rollback stop completed; recovery data was preserved.'
}

delete_ufw_rules_with_marker() {
    local marker="$1" number
    while true; do
        number="$(ufw status numbered | awk -v marker="${marker}" '
          index($0, marker) {
            if (match($0, /\[[[:space:]]*[0-9]+\]/)) {
              n = substr($0, RSTART + 1, RLENGTH - 2)
              gsub(/[[:space:]]/, "", n)
              print n
              exit
            }
          }
        ')"
        [[ -n "${number}" ]] || break
        ufw --force delete "${number}" >/dev/null
    done
}

rollback_host_stage() {
    local answer="${RW_CONFIRM_HOST_ROLLBACK:-}" initial_status='unknown'
    announce_stage rollback-host
    require_root
    load_state
    if [[ "${answer}" != RESTORE ]]; then
        if [[ "${NON_INTERACTIVE}" == 1 || ! -t 0 ]]; then
            die 'Set RW_CONFIRM_HOST_ROLLBACK=RESTORE to authorize host firewall/tuning restoration.'
        fi
        warn 'This removes only wizard-commented UFW rules and restores the recorded pre-tuning sysctls.'
        confirm_phrase 'Wizard containers will stop and recorded host changes will be restored.' RESTORE || \
            die 'Host rollback was not authorized.'
    fi
    rollback_stage
    if [[ "${SKIP_UFW}" != 1 ]]; then
        delete_ufw_rules_with_marker "Remnawave Panel ${NODE_CODE}"
        delete_ufw_rules_with_marker "Remnawave edge ${NODE_CODE}"
        delete_ufw_rules_with_marker "Remnawave Hysteria2 ${NODE_CODE}"
        [[ ! -f "${PRIVATE_DIR}/ufw-initial-status" ]] || \
            initial_status="$(<"${PRIVATE_DIR}/ufw-initial-status")"
        if [[ "${initial_status}" == inactive ]]; then
            ufw --force disable >/dev/null
        elif [[ "${initial_status}" == active ]]; then
            ufw reload >/dev/null
        fi
    fi
    if [[ -f "${PRIVATE_DIR}/sysctl-before.txt" ]]; then
        restore_tuning_loaded
    fi
    log 'Explicit host rollback completed; DNS and generated files were preserved.'
}

bootstrap_stage() {
    local distro_id distro_codename architecture key_tmp
    announce_stage bootstrap
    require_root
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates coreutils curl dnsutils iproute2 jq kmod openssl procps python3 ufw util-linux
    if ! command -v docker >/dev/null 2>&1; then
        # Use Docker's signed production apt repository. The convenience script
        # is deliberately not used because Docker documents it for testing and
        # development rather than reproducible production provisioning.
        # shellcheck disable=SC1091
        source /etc/os-release
        distro_id="${ID:-}"
        distro_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        architecture="$(dpkg --print-architecture)"
        case "${distro_id}" in
            ubuntu|debian) ;;
            *) die "bootstrap supports official Ubuntu or Debian only; detected ${distro_id:-unknown}." ;;
        esac
        [[ -n "${distro_codename}" ]] || die 'Could not determine the distribution codename.'
        install -d -m 0755 /etc/apt/keyrings
        key_tmp="$(mktemp /etc/apt/keyrings/.docker.asc.XXXXXX)"
        if ! curl --fail --silent --show-error --location \
            "https://download.docker.com/linux/${distro_id}/gpg" --output "${key_tmp}"; then
            find "${key_tmp}" -maxdepth 0 -delete
            die 'Could not download Docker official signing key.'
        fi
        chmod 0644 "${key_tmp}"
        mv -f -- "${key_tmp}" /etc/apt/keyrings/docker.asc
        {
            printf 'Types: deb\n'
            printf 'URIs: https://download.docker.com/linux/%s\n' "${distro_id}"
            printf 'Suites: %s\n' "${distro_codename}"
            printf 'Components: stable\n'
            printf 'Architectures: %s\n' "${architecture}"
            printf 'Signed-By: /etc/apt/keyrings/docker.asc\n'
        } >/etc/apt/sources.list.d/docker.sources
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    if ! docker compose version >/dev/null 2>&1; then
        if ! apt-get install -y docker-compose-v2; then
            apt-get install -y docker-compose-plugin || \
                die 'The existing Docker installation has no compatible Compose v2 plugin.'
        fi
    fi
    systemctl enable --now docker
    log 'Base tools are installed. UFW was intentionally not enabled or given an SSH policy.'
}

all_stage() {
    announce_stage all
    if ! base_commands_ready; then
        log 'Missing base packages detected; running bootstrap first.'
        bootstrap_stage
    fi
    init_stage
    load_state
    panel_stage
    wait_for_enter 'Create the Config Profile and Node in Panel, then copy its SECRET_KEY.'
    node_stage
    wait_for_enter 'Create the canary squad/user and all enabled physical Hosts in Panel.'
    template_stage
    sed -n '1,240p' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
    wait_for_enter 'Attach the AUTO template, create the AUTO Host, and verify the canary subscription.'
    edge_stage
    verify_auth_stage
}

check_repository_secret_hygiene() {
    local script_path repo_root candidate value
    command -v git >/dev/null 2>&1 || return 0
    script_path="$(realpath -m -- "${BASH_SOURCE[0]}")"
    repo_root="$(git -C "$(dirname "${script_path}")" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "${repo_root}" && -d "${repo_root}/deploy/ru-resilient-edge" ]] || return 0
    while IFS= read -r -d '' candidate; do
        git -C "${repo_root}" check-ignore -q --no-index -- "${candidate}" && continue
        value="$(sed -n 's/^SECRET_KEY=//p' "${candidate}" | head -n 1)"
        if ((${#value} >= 64)) && [[ "${value}" != __* ]]; then
            die "Unignored file appears to contain a real SECRET_KEY: ${candidate}"
        fi
    done < <(find "${repo_root}/deploy/ru-resilient-edge" -type f \
        \( -name '.env*' -o -name '*.bak' -o -name '*.bak-*' \) -print0)
}

selftest_stage() {
    local original_install temp_root
    announce_stage selftest
    require_root
    need_commands
    original_install="${INSTALL_DIR}"
    temp_root="$(mktemp -d /tmp/remnawave-edge-selftest.XXXXXX)"
    selftest_cleanup() {
        rm -rf -- "${temp_root}"
        INSTALL_DIR="${original_install}"
        set_paths
    }
    trap selftest_cleanup EXIT RETURN
    INSTALL_DIR="${temp_root}/rendered"
    set_paths
    REALITY_SNI='reality.example.com'
    XHTTP_SNI='xhttp.example.net'
    EDGE_IPV4='192.0.2.10'
    PANEL_IPV4='198.51.100.20'
    ACME_EMAIL='admin@example.com'
    NODE_PORT='3334'
    NODE_SLUG='selftest-node'
    NODE_CODE='A1B2C3D4'
    NODE_CODE_LOWER='a1b2c3d4'
    PROFILE_NAME='RW-EDGE-A1B2C3D4'
    RAW_TAG='RW_A1B2C3D4_RAW_REALITY'
    XHTTP_TAG='RW_A1B2C3D4_XHTTP_TLS'
    HYSTERIA_TAG='RW_A1B2C3D4_HYSTERIA2'
    ENABLE_HYSTERIA=1
    ENABLE_RAW_FRAGMENT=1
    CLIENT_FINGERPRINT='firefox'
    BLOCK_CLIENT_QUIC=1
    APPLY_TUNING=1
    NODE_CONTAINER='rw-edge-node-a1b2c3d4'
    HAPROXY_CONTAINER='rw-edge-haproxy-a1b2c3d4'
    CADDY_CONTAINER='rw-edge-caddy-a1b2c3d4'
    COMPOSE_PROJECT='rw-edge-a1b2c3d4'
    RAW_HOST_UUID='11111111-1111-4111-8111-111111111111'
    RAW_FRAGMENT_HOST_UUID='55555555-5555-4555-8555-555555555555'
    XHTTP_HOST_UUID='22222222-2222-4222-8222-222222222222'
    HYSTERIA_HOST_UUID='44444444-4444-4444-8444-444444444444'
    EXTRA_HOST_UUIDS='33333333-3333-4333-8333-333333333333'
    pull_images
    generate_material
    generate_hysteria_certificate
    write_state
    render_all_files
    ensure_node_env_placeholder
    validate_artifacts
    bash -n "${BASH_SOURCE[0]}"
    check_repository_secret_hygiene
    success 'PASS: isolated render-only selftest; no firewall, DNS or service state was changed.'
    trap - EXIT RETURN
    selftest_cleanup
}

main() {
    local command="${1:-}" started_at="${SECONDS}"
    SELECTED_COMMAND=''
    ui_init
    show_banner
    if [[ -z "${command}" && "${UI_TTY}" == 1 ]]; then
        choose_command
        command="${SELECTED_COMMAND}"
    fi
    set_paths
    case "${command}" in
        -h|--help|help|'') ;;
        *) acquire_global_lock ;;
    esac
    case "${command}" in
        bootstrap) bootstrap_stage ;;
        init) init_stage ;;
        panel) panel_stage ;;
        node) node_stage ;;
        template) template_stage ;;
        edge) edge_stage ;;
        verify) verify_stage ;;
        verify-auth) verify_auth_stage ;;
        tune) tune_stage ;;
        untune) untune_stage ;;
        status) status_stage ;;
        all) all_stage ;;
        rollback) rollback_stage ;;
        rollback-host) rollback_host_stage ;;
        selftest) selftest_stage ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; die "Unknown command: ${command}" ;;
    esac
    case "${command}" in
        -h|--help|help|'') ;;
        *)
            ui_rule
            success "Command '${command}' completed in $((SECONDS - started_at))s."
            ;;
    esac
}

main "$@"
