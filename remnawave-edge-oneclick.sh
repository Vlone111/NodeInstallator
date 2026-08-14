#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

# Remnawave Panel 2.8.1 / Node 2.8.0 one-file edge wizard.
#
# Data plane:
#   TCP/443 -> HAProxy SNI router -> selected self/external RAW+REALITY or
#              Caddy -> optional XHTTP auto (HTTP/2 normally selects stream-up)
#   UDP/443 -> optional Hysteria2
#
# RAW uses a real local HTTPS site as REALITY's self-steal target.  Client Hosts
# default to the Firefox uTLS fingerprint.  An optional isolated Host applies
# client-side ClientHello fragmentation to one selected REALITY path; FinalMask is never placed
# on a REALITY server inbound because Xray 26.6.27 has a known crash regression
# in that combination.  The script never edits Panel directly: SECRET_KEY and
# Host UUIDs are Panel outputs and are requested only at explicit stage gates.

SCRIPT_VERSION='2026-08-14.2'
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
EXTERNAL_REALITY_BACKEND_PORT=18445
CADDY_BACKEND_PORT=19443
HAPROXY_STATS_PORT=8404
HYSTERIA_MASQ_PORT=19080
CADDY_DATA_CONTAINER_DIR='/var/lib/remnawave-edge/caddy-data'
CADDY_LE_STORAGE_ID='acme-v02.api.letsencrypt.org-directory'
RAW_TEST_PORT=21081
XHTTP_TEST_PORT=21082
HYSTERIA_TEST_PORT=21083
RAW_FRAGMENT_TEST_PORT=21084
EXTERNAL_REALITY_TEST_PORT=21085

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
  RW_ENABLE_SELF_REALITY=0|1, RW_ENABLE_EXTERNAL_REALITY=0|1,
  RW_ENABLE_XHTTP=0|1, RW_ENABLE_HYSTERIA=0|1,
  RW_EXTERNAL_REALITY_TARGET=host:443, RW_EXTERNAL_REALITY_SNI=host,
  RW_ENABLE_RAW_FRAGMENT=0|1, RW_FRAGMENT_REALITY=self|external,
  RW_CLIENT_FINGERPRINT (default: firefox),
  RW_BLOCK_CLIENT_QUIC=0|1, RW_APPLY_TUNING=0|1,
  RW_SKIP_DNS=1, RW_SKIP_UFW=1, RW_SSH_PORT,
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

persist_installer() {
    local source_path="${BASH_SOURCE[0]}" target_path="${INSTALL_DIR}/remnawave-edge-oneclick.sh"
    install -d -m 0755 "${INSTALL_DIR}"
    if [[ -r "${source_path}" ]] && \
       [[ "$(realpath -m -- "${source_path}")" != "$(realpath -m -- "${target_path}")" ]]; then
        install -m 0700 "${source_path}" "${target_path}"
    elif [[ ! -x "${target_path}" ]]; then
        warn "Could not persist the running installer at ${target_path}; keep the launch command for resume."
        return 0
    fi
    log "Reusable installer saved at ${target_path}."
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

normalize_external_target() {
    local target="${1,,}"
    case "${target}" in
        amd) target='www.amd.com' ;;
        tesla) target='www.tesla.com' ;;
        dl.google|google|google-downloads) target='dl.google.com' ;;
    esac
    [[ "${target}" == *:* ]] || target+=':443'
    printf '%s' "${target}"
}

validate_external_target_format() {
    local target host port
    target="$(normalize_external_target "$1")"
    host="${target%:*}"
    port="${target##*:}"
    validate_fqdn "${host}" && [[ "${port}" == 443 ]]
}

probe_external_reality_target() {
    local target="$1" sni="$2" quiet="${3:-0}" host port addresses tls_output xray_output timing sample
    local -a address_list=()
    local -a timing_samples=()
    target="$(normalize_external_target "${target}")"
    host="${target%:*}"
    port="${target##*:}"
    validate_external_target_format "${target}" || return 1
    validate_fqdn "${sni}" || return 1
    [[ "${host}" == "${sni}" ]] || return 1
    addresses="$(getent ahostsv4 "${host}" 2>/dev/null | awk '$2 == "STREAM" {print $1}' | sort -u)"
    [[ -n "${addresses}" ]] || return 1
    mapfile -t address_list <<<"${addresses}"
    if ! python3 - "${EDGE_IPV4:-192.0.2.1}" "${address_list[@]}" <<'PY' >/dev/null 2>&1
import ipaddress, sys
edge = ipaddress.ip_address(sys.argv[1])
for value in sys.argv[2:]:
    address = ipaddress.ip_address(value)
    assert address != edge
    assert not (address.is_private or address.is_loopback or address.is_link_local or address.is_multicast or address.is_unspecified)
PY
    then
        return 1
    fi
    tls_output="$(timeout 12 openssl s_client -connect "${target}" -servername "${sni}" \
        -tls1_3 -verify_hostname "${sni}" -verify_return_error -CApath /etc/ssl/certs \
        -alpn 'h2,http/1.1' -brief </dev/null 2>&1 || true)"
    grep -Fq 'Protocol version: TLSv1.3' <<<"${tls_output}" || return 1
    grep -Fq 'Verification: OK' <<<"${tls_output}" || return 1
    xray_output="$(timeout 20 docker run --rm --pull never --network host --cap-drop ALL \
        --read-only --security-opt no-new-privileges:true \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" tls ping "${sni}" 2>&1 || true)"
    [[ "$(grep -Fc 'Handshake succeeded' <<<"${xray_output}")" -ge 2 ]] || return 1
    grep -Fq 'TLS Version:' <<<"${xray_output}" || return 1
    grep -Fq 'TLS 1.3' <<<"${xray_output}" || return 1
    for _ in 1 2 3; do
        sample="$(curl --silent --show-error --output /dev/null --connect-timeout 4 --max-time 10 \
            --write-out '%{time_appconnect}' "https://${sni}/" 2>/dev/null || true)"
        if [[ "${sample}" =~ ^[0-9]+\.[0-9]+$ && "${sample}" != 0.000000 ]]; then
            timing_samples+=("${sample}")
        fi
    done
    if ((${#timing_samples[@]} >= 2)); then
        timing="$(printf '%s\n' "${timing_samples[@]}" | sort -n | sed -n '2p')"
    elif ((${#timing_samples[@]} == 1)); then
        timing="${timing_samples[0]}"
    else
        timing='9.999999'
    fi
    EXTERNAL_TARGET_LAST_SCORE="${timing}"
    EXTERNAL_TARGET_LAST_IPS="$(paste -sd, <<<"${addresses}")"
    EXTERNAL_TARGET_LAST_PQ=0
    grep -Eq 'TLS Post-Quantum key exchange:[[:space:]]+true' <<<"${xray_output}" && \
        EXTERNAL_TARGET_LAST_PQ=1
    if [[ "${quiet}" != 1 ]]; then
        success "External REALITY target ${target} passed TLS 1.3, hostname and Xray probes (${EXTERNAL_TARGET_LAST_IPS})."
        [[ "${EXTERNAL_TARGET_LAST_PQ}" == 1 ]] || \
            warn "${target} did not negotiate post-quantum TLS in the current Xray probe."
    fi
}

select_external_reality_target() {
    local requested="${RW_EXTERNAL_REALITY_TARGET:-}" requested_sni="${RW_EXTERNAL_REALITY_SNI:-}"
    local candidate best_target='' best_sni='' best_score='99.999999'
    local -a candidates=('dl.google.com:443' 'www.amd.com:443' 'www.tesla.com:443')
    if [[ -n "${requested}" ]]; then
        EXTERNAL_REALITY_TARGET="$(normalize_external_target "${requested}")"
        EXTERNAL_REALITY_SNI="${requested_sni:-${EXTERNAL_REALITY_TARGET%:*}}"
        probe_external_reality_target "${EXTERNAL_REALITY_TARGET}" "${EXTERNAL_REALITY_SNI}" || \
            die "External REALITY target ${EXTERNAL_REALITY_TARGET} failed DNS/TLS/Xray validation."
        return 0
    fi
    log 'Benchmarking external REALITY targets from this Node...'
    for candidate in "${candidates[@]}"; do
        if probe_external_reality_target "${candidate}" "${candidate%:*}" 1; then
            log "Candidate ${candidate}: TLS=${EXTERNAL_TARGET_LAST_SCORE}s, IP=${EXTERNAL_TARGET_LAST_IPS}, PQ=${EXTERNAL_TARGET_LAST_PQ}."
            if awk -v current="${EXTERNAL_TARGET_LAST_SCORE}" -v best="${best_score}" \
                'BEGIN {exit !(current < best)}'; then
                best_target="${candidate}"
                best_sni="${candidate%:*}"
                best_score="${EXTERNAL_TARGET_LAST_SCORE}"
            fi
        else
            warn "Candidate ${candidate} failed the current DNS/TLS/Xray probe and was excluded."
        fi
    done
    [[ -n "${best_target}" ]] || die 'No external REALITY preset passed validation; rerun with a verified custom target.'
    EXTERNAL_REALITY_TARGET="${best_target}"
    EXTERNAL_REALITY_SNI="${best_sni}"
    success "Selected ${EXTERNAL_REALITY_TARGET} as the fastest currently valid regional target (TLS ${best_score}s)."
}

caddy_volume_name() {
    printf '%s-caddy-data' "${COMPOSE_PROJECT}"
}

hysteria_cert_relative_dir() {
    printf 'caddy/certificates/%s/%s' "${CADDY_LE_STORAGE_ID}" "${XHTTP_SNI}"
}

hysteria_cert_container_path() {
    printf '%s/%s/%s.crt' "${CADDY_DATA_CONTAINER_DIR}" \
        "$(hysteria_cert_relative_dir)" "${XHTTP_SNI}"
}

hysteria_key_container_path() {
    printf '%s/%s/%s.key' "${CADDY_DATA_CONTAINER_DIR}" \
        "$(hysteria_cert_relative_dir)" "${XHTTP_SNI}"
}

caddy_hysteria_material_paths() {
    local mountpoint
    mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$(caddy_volume_name)" 2>/dev/null || true)"
    [[ -n "${mountpoint}" ]] || return 1
    printf '%s\n%s\n' \
        "${mountpoint}/$(hysteria_cert_relative_dir)/${XHTTP_SNI}.crt" \
        "${mountpoint}/$(hysteria_cert_relative_dir)/${XHTTP_SNI}.key"
}

validate_hysteria_material() {
    local cert key cert_pubkey key_pubkey subject issuer
    local -a material=()
    mapfile -t material < <(caddy_hysteria_material_paths)
    ((${#material[@]} == 2)) || \
        die 'Caddy certificate storage for Hysteria2 does not exist yet.'
    cert="${material[0]}"
    key="${material[1]}"
    [[ -s "${cert}" && -s "${key}" ]] || \
        die "Caddy has not stored the Hysteria2 certificate for ${XHTTP_SNI}."
    openssl x509 -in "${cert}" -noout -checkhost "${XHTTP_SNI}" >/dev/null || \
        die 'Caddy Hysteria2 certificate SAN does not match the configured domain.'
    openssl x509 -in "${cert}" -noout -checkend 1209600 >/dev/null || \
        die 'Caddy Hysteria2 certificate expires in less than 14 days.'
    subject="$(openssl x509 -in "${cert}" -noout -subject -nameopt RFC2253)"
    issuer="$(openssl x509 -in "${cert}" -noout -issuer -nameopt RFC2253)"
    [[ "${subject#subject=}" != "${issuer#issuer=}" ]] || \
        die 'Caddy Hysteria2 certificate is self-signed; a public ACME chain is required.'
    cert_pubkey="$(openssl x509 -in "${cert}" -pubkey -noout | \
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)"
    key_pubkey="$(openssl pkey -in "${key}" -pubout -outform DER 2>/dev/null | \
        openssl dgst -sha256)"
    [[ -n "${cert_pubkey}" && "${cert_pubkey}" == "${key_pubkey}" ]] || \
        die 'Caddy Hysteria2 certificate and private key do not match.'
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

normalize_yes_no_answer() {
    local answer="$1"
    # Some SSH/web consoles append CR or whitespace to pasted single-key
    # answers. Strip both ends before applying ASCII case folding.
    answer="${answer//$'\r'/}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    printf '%s' "${answer,,}"
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
        answer="$(normalize_yes_no_answer "${answer}")"
        case "${answer}" in
            '') printf -v "${variable}" '%s' "${default_value}"; return 0 ;;
            y|yes|1|true|on) printf -v "${variable}" '%s' 1; return 0 ;;
            n|no|0|false|off) printf -v "${variable}" '%s' 0; return 0 ;;
            *) warn "Please answer y or n, or press Enter for the ${suffix:0:1} default." ;;
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
        printf 'EXTERNAL_REALITY_TAG=%q\n' "${EXTERNAL_REALITY_TAG}"
        printf 'HYSTERIA_TAG=%q\n' "${HYSTERIA_TAG}"
        printf 'ENABLE_SELF_REALITY=%q\n' "${ENABLE_SELF_REALITY}"
        printf 'ENABLE_EXTERNAL_REALITY=%q\n' "${ENABLE_EXTERNAL_REALITY}"
        printf 'ENABLE_XHTTP=%q\n' "${ENABLE_XHTTP}"
        printf 'ENABLE_HYSTERIA=%q\n' "${ENABLE_HYSTERIA}"
        printf 'ENABLE_RAW_FRAGMENT=%q\n' "${ENABLE_RAW_FRAGMENT}"
        printf 'FRAGMENT_REALITY=%q\n' "${FRAGMENT_REALITY}"
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
        [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || {
            printf 'EXTERNAL_REALITY_TARGET=%q\n' "${EXTERNAL_REALITY_TARGET}"
            printf 'EXTERNAL_REALITY_SNI=%q\n' "${EXTERNAL_REALITY_SNI}"
            printf 'EXTERNAL_REALITY_PRIVATE_KEY=%q\n' "${EXTERNAL_REALITY_PRIVATE_KEY}"
            printf 'EXTERNAL_REALITY_PUBLIC_KEY=%q\n' "${EXTERNAL_REALITY_PUBLIC_KEY}"
            printf 'EXTERNAL_REALITY_SHORT_ID=%q\n' "${EXTERNAL_REALITY_SHORT_ID}"
        }
        printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH}"
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
    for required in REALITY_SNI EDGE_IPV4 PANEL_IPV4 ACME_EMAIL NODE_PORT \
        NODE_CODE NODE_CODE_LOWER PROFILE_NAME NODE_CONTAINER HAPROXY_CONTAINER \
        CADDY_CONTAINER COMPOSE_PROJECT; do
        [[ -n "${!required:-}" ]] || missing+=("${required}")
    done
    ((${#missing[@]} == 0)) || die "Incompatible state.env in ${INSTALL_DIR}; missing wizard fields: ${missing[*]}. Use the install directory that this wizard initialized."
    NODE_SLUG="${NODE_SLUG:-${NODE_CODE_LOWER:-legacy-node}}"
    ENABLE_SELF_REALITY="${ENABLE_SELF_REALITY:-1}"
    ENABLE_EXTERNAL_REALITY="${ENABLE_EXTERNAL_REALITY:-0}"
    ENABLE_XHTTP="${ENABLE_XHTTP:-1}"
    ENABLE_HYSTERIA="${ENABLE_HYSTERIA:-0}"
    # Client FinalMask is an opt-in canary.  Keep legacy state files safe: Happ
    # releases that bundle Xray <= 26.5.9 reject the newer plural
    # `lengths`/`delays` fragment schema before the client core can start.
    ENABLE_RAW_FRAGMENT="${ENABLE_RAW_FRAGMENT:-0}"
    FRAGMENT_REALITY="${FRAGMENT_REALITY:-self}"
    CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT:-firefox}"
    CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT,,}"
    BLOCK_CLIENT_QUIC="${BLOCK_CLIENT_QUIC:-1}"
    APPLY_TUNING="${APPLY_TUNING:-0}"
    XHTTP_SNI="${XHTTP_SNI:-${REALITY_SNI}}"
    RAW_TAG="${RAW_TAG:-RW_${NODE_CODE}_RAW_REALITY_SELF}"
    XHTTP_TAG="${XHTTP_TAG:-RW_${NODE_CODE}_XHTTP_TLS}"
    EXTERNAL_REALITY_TAG="${EXTERNAL_REALITY_TAG:-RW_${NODE_CODE}_RAW_REALITY_EXTERNAL}"
    HYSTERIA_TAG="${HYSTERIA_TAG:-RW_${NODE_CODE}_HYSTERIA2}"

    missing=()
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        for required in RAW_TAG REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID; do
            [[ -n "${!required:-}" ]] || missing+=("${required}")
        done
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        for required in EXTERNAL_REALITY_TAG EXTERNAL_REALITY_TARGET EXTERNAL_REALITY_SNI \
            EXTERNAL_REALITY_PRIVATE_KEY EXTERNAL_REALITY_PUBLIC_KEY EXTERNAL_REALITY_SHORT_ID; do
            [[ -n "${!required:-}" ]] || missing+=("${required}")
        done
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        for required in XHTTP_TAG XHTTP_SNI XHTTP_PATH; do
            [[ -n "${!required:-}" ]] || missing+=("${required}")
        done
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        for required in HYSTERIA_TAG XHTTP_SNI; do
            [[ -n "${!required:-}" ]] || missing+=("${required}")
        done
    fi
    ((${#missing[@]} == 0)) || die "Incomplete selected-transport state in ${INSTALL_DIR}: ${missing[*]}."
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
    local key_output external_key_output
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
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        external_key_output="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
            --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" x25519)"
        EXTERNAL_REALITY_PRIVATE_KEY="$(printf '%s\n' "${external_key_output}" | sed -nE \
            's/^(PrivateKey|Private key):[[:space:]]*//p' | head -n 1)"
        EXTERNAL_REALITY_PUBLIC_KEY="$(printf '%s\n' "${external_key_output}" | sed -nE \
            's/^(Password \(PublicKey\)|Password|PublicKey|Public key):[[:space:]]*//p' | head -n 1)"
        EXTERNAL_REALITY_SHORT_ID="$(openssl rand -hex 8)"
        [[ -n "${EXTERNAL_REALITY_PRIVATE_KEY}" && -n "${EXTERNAL_REALITY_PUBLIC_KEY}" ]] || \
            die 'Xray did not generate external REALITY keys.'
        [[ "${EXTERNAL_REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || \
            die 'Invalid generated external REALITY short ID.'
    fi
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
  "inbounds": [],
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
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        jq --arg tag "${RAW_TAG}" --arg sni "${REALITY_SNI}" \
            --arg private_key "${REALITY_PRIVATE_KEY}" --arg short_id "${REALITY_SHORT_ID}" \
            --argjson port "${RAW_BACKEND_PORT}" --argjson cover_port "${CADDY_BACKEND_PORT}" '
          .inbounds += [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none"},
            streamSettings: {
              network: "raw", security: "reality",
              realitySettings: {
                show: false, target: ("127.0.0.1:" + ($cover_port | tostring)), xver: 0,
                serverNames: [$sni], privateKey: $private_key, shortIds: [$short_id]
              },
              sockopt: {acceptProxyProtocol: true}
            },
            sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
          }]
        ' "${PRIVATE_DIR}/config-profile.ready.json" >"${PRIVATE_DIR}/config-profile.ready.json.tmp"
        mv -f "${PRIVATE_DIR}/config-profile.ready.json.tmp" "${PRIVATE_DIR}/config-profile.ready.json"
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        jq --arg tag "${EXTERNAL_REALITY_TAG}" --arg target "${EXTERNAL_REALITY_TARGET}" \
            --arg sni "${EXTERNAL_REALITY_SNI}" --arg private_key "${EXTERNAL_REALITY_PRIVATE_KEY}" \
            --arg short_id "${EXTERNAL_REALITY_SHORT_ID}" \
            --argjson port "${EXTERNAL_REALITY_BACKEND_PORT}" '
          .inbounds += [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none"},
            streamSettings: {
              network: "raw", security: "reality",
              realitySettings: {
                show: false, target: $target, xver: 0, serverNames: [$sni],
                privateKey: $private_key, shortIds: [$short_id],
                limitFallbackUpload: {
                  afterBytes: 4194304, bytesPerSec: 1048576, burstBytesPerSec: 4194304
                },
                limitFallbackDownload: {
                  afterBytes: 4194304, bytesPerSec: 1048576, burstBytesPerSec: 4194304
                }
              },
              sockopt: {acceptProxyProtocol: true}
            },
            sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
          }]
        ' "${PRIVATE_DIR}/config-profile.ready.json" >"${PRIVATE_DIR}/config-profile.ready.json.tmp"
        mv -f "${PRIVATE_DIR}/config-profile.ready.json.tmp" "${PRIVATE_DIR}/config-profile.ready.json"
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        jq --arg tag "${XHTTP_TAG}" --arg path "${XHTTP_PATH}" \
            --argjson port "${XHTTP_BACKEND_PORT}" '
          .inbounds += [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none"},
            streamSettings: {
              network: "xhttp", security: "none",
              xhttpSettings: {path: $path, mode: "auto"}
            },
            sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
          }]
        ' "${PRIVATE_DIR}/config-profile.ready.json" >"${PRIVATE_DIR}/config-profile.ready.json.tmp"
        mv -f "${PRIVATE_DIR}/config-profile.ready.json.tmp" "${PRIVATE_DIR}/config-profile.ready.json"
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        jq --arg tag "${HYSTERIA_TAG}" --arg server_name "${XHTTP_SNI}" \
            --arg cert_path "$(hysteria_cert_container_path)" \
            --arg key_path "$(hysteria_key_container_path)" \
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
                  serverName: $server_name,
                  certificates: [{
                    certificateFile: $cert_path,
                    keyFile: $key_path,
                    oneTimeLoading: false
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
    use_backend caddy_tls if is_acme
EOF
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/haproxy.cfg" <<EOF
    acl is_reality_self req.ssl_sni -i "${REALITY_SNI}"
    use_backend xray_reality_self if is_reality_self
EOF
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/haproxy.cfg" <<EOF
    acl is_reality_external req.ssl_sni -i "${EXTERNAL_REALITY_SNI}"
    use_backend xray_reality_external if is_reality_external
EOF
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/haproxy.cfg" <<EOF
    acl is_xhttp req.ssl_sni -i "${XHTTP_SNI}"
    use_backend caddy_tls if is_xhttp
EOF
    fi
    cat >>"${INSTALL_DIR}/haproxy.cfg" <<'EOF'
    default_backend caddy_tls

backend caddy_tls
    mode tcp
    option tcp-check
    server caddy_local 127.0.0.1:19443 check inter 2s fall 3 rise 1
EOF
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/haproxy.cfg" <<EOF

backend xray_reality_self
    mode tcp
    option tcp-check
    server xray_self 127.0.0.1:${RAW_BACKEND_PORT} send-proxy-v2 check inter 5s fall 3 rise 2
EOF
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/haproxy.cfg" <<EOF

backend xray_reality_external
    mode tcp
    option tcp-check
    server xray_external 127.0.0.1:${EXTERNAL_REALITY_BACKEND_PORT} send-proxy-v2 check inter 5s fall 3 rise 2
EOF
    fi
    cat >>"${INSTALL_DIR}/haproxy.cfg" <<'EOF'

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
    cert_issuer acme {
        dir https://acme-v02.api.letsencrypt.org/directory
        disable_http_challenge
        alt_tlsalpn_port 19443
    }
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
    @documents path / /index.html /status.html /about.html /404.html
    header @documents Cache-Control "no-cache"
    @assets path *.css *.js *.svg *.webmanifest
    header @assets Cache-Control "public, max-age=86400, stale-while-revalidate=604800"
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
        protocols tls1.2 tls1.3
        curves x25519mlkem768 x25519
    }
    import common_site
    @sitemap path /sitemap.xml
    header @sitemap Content-Type "application/xml; charset=utf-8"
    respond @sitemap `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://{$REALITY_SNI}/</loc></url>
  <url><loc>https://{$REALITY_SNI}/status.html</loc></url>
  <url><loc>https://{$REALITY_SNI}/about.html</loc></url>
</urlset>` 200
    file_server
}
EOF
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/Caddyfile" <<'EOF'

https://{$XHTTP_SNI}:19443 {
    bind 127.0.0.1
    tls {
        protocols tls1.2 tls1.3
        curves x25519mlkem768 x25519
    }
    import common_site
    @sitemap path /sitemap.xml
    header @sitemap Content-Type "application/xml; charset=utf-8"
    respond @sitemap `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://{$XHTTP_SNI}/</loc></url>
  <url><loc>https://{$XHTTP_SNI}/status.html</loc></url>
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
    fi
    chmod 0644 "${INSTALL_DIR}/Caddyfile"
}

render_site() {
    install -d -m 0755 "${INSTALL_DIR}/site"
    cat >"${INSTALL_DIR}/site/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="theme-color" content="#071018">
  <meta name="description" content="Independent endpoint availability, latency and browser route diagnostics">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="manifest" href="/site.webmanifest">
  <link rel="stylesheet" href="/site.css">
  <title>Northstar · Edge Observatory</title>
</head>
<body>
  <div class="ambient ambient-a" aria-hidden="true"></div><div class="ambient ambient-b" aria-hidden="true"></div>
  <header class="nav wrap">
    <a class="brand" href="/" aria-label="Northstar home"><span class="brand-mark">N</span><span>Northstar</span></a>
    <nav aria-label="Primary"><a class="active" href="/">Overview</a><a href="/status.html">Status</a><a href="/about.html">Method</a></nav>
    <a class="nav-action" href="/status.html">Open diagnostics <span aria-hidden="true">↗</span></a>
  </header>
  <main>
    <section class="hero wrap">
      <div class="hero-copy">
        <p class="eyebrow"><span class="pulse"></span> Independent edge observatory</p>
        <h1>See the route.<br><em>Know the signal.</em></h1>
        <p class="lead">A private, same-origin view of endpoint reachability, response time and browser network state. No account, tracking or third-party requests.</p>
        <div class="hero-actions"><button id="run" type="button">Run live check</button><a class="button ghost" href="/about.html">How it works</a></div>
        <div class="trust-row"><span>Same-origin only</span><span>No cookies</span><span>Open methodology</span></div>
      </div>
      <aside class="signal-card" aria-label="Live endpoint signal">
        <div class="signal-head"><span>Live signal</span><span id="result" class="status"><i></i> Initialising</span></div>
        <div class="orbital" aria-hidden="true"><div class="orbit orbit-one"></div><div class="orbit orbit-two"></div><div class="core"><span id="latencyBig">—</span><small>median ms</small></div></div>
        <div class="signal-foot"><span><small>Endpoint</small><strong id="host">checking…</strong></span><span><small>Last sample</small><strong id="checked">pending</strong></span></div>
      </aside>
    </section>
    <section class="metric-strip wrap" aria-live="polite">
      <article><span class="metric-icon">↯</span><div><small>Median response</small><strong id="latency">Not measured</strong></div></article>
      <article><span class="metric-icon">≋</span><div><small>Sample jitter</small><strong id="jitter">Not measured</strong></div></article>
      <article><span class="metric-icon">⌁</span><div><small>Browser network</small><strong id="online">Checking</strong></div></article>
      <article><span class="metric-icon">◇</span><div><small>Secure context</small><strong id="secure">Checking</strong></div></article>
    </section>
    <section class="workspace wrap">
      <article class="chart-card">
        <div class="section-head"><div><p class="eyebrow">Current session</p><h2>Response timeline</h2></div><span class="legend"><i></i> browser observed</span></div>
        <div id="timeline" class="timeline" role="img" aria-label="Response-time samples"><span class="empty-chart">Run a check to populate the timeline</span></div>
        <div class="chart-axis"><span>oldest</span><span>latest</span></div>
      </article>
      <aside class="checks-card">
        <p class="eyebrow">Checks</p><h2>Endpoint layers</h2>
        <ul class="checks">
          <li><span class="check-icon" data-check="dns">1</span><div><strong>Hostname</strong><small id="dnsState">Resolving current origin</small></div></li>
          <li><span class="check-icon" data-check="tls">2</span><div><strong>Secure transport</strong><small id="tlsState">Verifying browser context</small></div></li>
          <li><span class="check-icon" data-check="http">3</span><div><strong>Origin response</strong><small id="httpState">Waiting for live sample</small></div></li>
        </ul>
        <a class="text-link" href="/status.html">View detailed status <span>→</span></a>
      </aside>
    </section>
    <section class="principles wrap">
      <div class="section-head"><div><p class="eyebrow">Designed for clarity</p><h2>Useful signal, minimal footprint.</h2></div><p>Every measurement is generated locally in this tab against the hostname already open in your browser.</p></div>
      <div class="feature-grid">
        <article><b>01</b><h3>Same-origin probes</h3><p>The check requests a tiny local health object. It contacts no analytics, ad network or external API.</p></article>
        <article><b>02</b><h3>Honest boundaries</h3><p>A green result confirms this endpoint at this moment—not the health of the entire internet.</p></article>
        <article><b>03</b><h3>Session-only data</h3><p>Samples remain in page memory and disappear when the tab closes. Nothing is uploaded.</p></article>
      </div>
    </section>
  </main>
  <footer><div class="wrap footer-grid"><div><a class="brand" href="/"><span class="brand-mark">N</span><span>Northstar</span></a><p>Independent browser-side endpoint diagnostics.</p></div><div><strong>Explore</strong><a href="/status.html">Live status</a><a href="/about.html">Method</a><a href="/health.txt">Raw health</a></div><div><strong>Principles</strong><span>No analytics</span><span>No accounts</span><span>No third parties</span></div></div><div class="wrap footer-bottom"><span>Northstar Edge Observatory</span><span id="year"></span></div></footer>
  <script src="/diagnostics.js" defer></script>
</body>
</html>
EOF
    cat >"${INSTALL_DIR}/site/about.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#071018"><meta name="description" content="Northstar measurement and privacy methodology"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/site.css"><title>Method · Northstar</title></head><body><header class="nav wrap"><a class="brand" href="/"><span class="brand-mark">N</span><span>Northstar</span></a><nav><a href="/">Overview</a><a href="/status.html">Status</a><a class="active" href="/about.html">Method</a></nav></header><main class="article-shell wrap"><div class="article-title"><p class="eyebrow">Open methodology</p><h1>Small probes.<br><em>Clear limits.</em></h1><p>Northstar is a self-contained browser diagnostic for the endpoint serving this page. Its job is to expose a useful local signal without pretending to be a global monitoring network.</p></div><article class="prose"><h2>What happens during a check</h2><p>The page requests <code>/health.txt</code> seven times with caching disabled. The browser measures each completed round trip. Northstar reports the median, approximate jitter and the slowest observed sample.</p><h2>What never happens</h2><p>There are no third-party scripts, analytics pixels, advertising calls, accounts or telemetry uploads. Results remain in JavaScript memory for the life of the page and are discarded when it closes.</p><div class="callout"><strong>Scope of a green result</strong><p>It confirms that DNS, a secure browser connection and this origin worked from this browser at that moment. It does not certify unrelated destinations or every network path.</p></div><h2>Why results can change</h2><p>Access networks, DNS caches, radio conditions, congestion and route selection all vary. A single measurement is a snapshot. Repeat checks and compare from the same access network before drawing conclusions.</p><h2>Data returned by the origin</h2><p>The health object contains only the text <code>ok</code>. Standard web-server access logs may contain ordinary request metadata needed for operations; the page itself adds no identifier.</p><p><a class="button" href="/">Run the live check</a></p></article></main><footer><div class="wrap footer-bottom"><span>Northstar Edge Observatory</span><span>Methodology</span></div></footer></body></html>
EOF
    cat >"${INSTALL_DIR}/site/status.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#071018"><meta name="description" content="Live Northstar endpoint status"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/site.css"><title>Status · Northstar</title></head><body><header class="nav wrap"><a class="brand" href="/"><span class="brand-mark">N</span><span>Northstar</span></a><nav><a href="/">Overview</a><a class="active" href="/status.html">Status</a><a href="/about.html">Method</a></nav></header><main class="status-page wrap"><section class="status-title"><p class="eyebrow"><span class="pulse"></span> Browser-side status</p><h1>Live endpoint<br><em>diagnostics.</em></h1><p>Run a fresh same-origin sample from this device and network.</p><button id="run" type="button">Run all checks</button></section><section class="status-banner"><div><span id="result" class="status"><i></i> Initialising</span><h2 id="bannerTitle">Preparing endpoint check</h2><p id="bannerText">No result has been recorded in this tab yet.</p></div><div class="banner-metric"><strong id="latencyBig">—</strong><span>median ms</span></div></section><section class="component-list"><article><span class="component-dot" data-check="dns"></span><div><h3>Hostname resolution</h3><p id="dnsState">Resolving current origin</p></div><strong id="host">checking…</strong></article><article><span class="component-dot" data-check="tls"></span><div><h3>HTTPS secure context</h3><p id="tlsState">Verifying browser context</p></div><strong id="secure">checking…</strong></article><article><span class="component-dot" data-check="http"></span><div><h3>Origin health object</h3><p id="httpState">Waiting for samples</p></div><strong id="online">checking…</strong></article></section><section class="report-card"><div><p class="eyebrow">Latest sample</p><h2>Diagnostic report</h2></div><dl><div><dt>Median</dt><dd id="latency">Not measured</dd></div><div><dt>Jitter</dt><dd id="jitter">Not measured</dd></div><div><dt>Checked</dt><dd id="checked">Pending</dd></div></dl><button id="copy" class="ghost" type="button">Copy report</button></section><div id="timeline" class="timeline compact" aria-label="Response-time samples"><span class="empty-chart">Run a check to populate the timeline</span></div></main><footer><div class="wrap footer-bottom"><span>Northstar Edge Observatory</span><a href="/about.html">Measurement limits</a></div></footer><script src="/diagnostics.js" defer></script></body></html>
EOF
    cat >"${INSTALL_DIR}/site/404.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#071018"><link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/site.css"><title>Not found · Northstar</title></head><body><main class="error-page"><div class="error-orbit"><span>404</span></div><p class="eyebrow">Route unavailable</p><h1>This coordinate<br>is not on the map.</h1><p>The endpoint is online, but the requested resource does not exist.</p><a class="button" href="/">Return to overview</a></main></body></html>
EOF
    cat >"${INSTALL_DIR}/site/site.css" <<'EOF'
:root{color-scheme:dark;--bg:#071018;--bg2:#0a151f;--panel:#0d1b26;--panel2:#102431;--line:#203541;--line2:#2b4653;--text:#eef7f4;--muted:#90a6aa;--accent:#81f4c1;--accent2:#5dc7ff;--danger:#ff8d8d;--ink:#04140d;--shadow:0 24px 70px rgba(0,0,0,.28)}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;min-height:100vh;overflow-x:hidden;background:var(--bg);color:var(--text);font:15px/1.65 Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}body:before{content:"";position:fixed;inset:0;pointer-events:none;opacity:.24;background-image:linear-gradient(rgba(255,255,255,.018) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.018) 1px,transparent 1px);background-size:56px 56px}.ambient{position:fixed;border-radius:50%;filter:blur(120px);pointer-events:none;opacity:.15}.ambient-a{width:520px;height:520px;right:-190px;top:-170px;background:var(--accent2)}.ambient-b{width:430px;height:430px;left:-220px;top:420px;background:var(--accent)}.wrap{width:min(1180px,calc(100% - 48px));margin-inline:auto}a{color:inherit}.nav{height:84px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid rgba(255,255,255,.09);position:relative;z-index:5}.brand{display:inline-flex;align-items:center;gap:11px;color:var(--text);text-decoration:none;font-size:.84rem;font-weight:850;letter-spacing:.14em;text-transform:uppercase}.brand-mark{display:grid;place-items:center;width:32px;height:32px;border:1px solid rgba(129,244,193,.5);border-radius:10px;color:var(--accent);background:rgba(129,244,193,.07);font-size:.82rem}.nav nav{display:flex;gap:32px}.nav nav a{position:relative;color:var(--muted);text-decoration:none;font-size:.88rem;font-weight:650;transition:.2s}.nav nav a:hover,.nav nav a.active{color:var(--text)}.nav nav a.active:after{content:"";position:absolute;left:0;right:0;bottom:-31px;height:2px;background:var(--accent)}.nav-action{padding:9px 14px;border:1px solid var(--line2);border-radius:10px;text-decoration:none;font-size:.8rem;font-weight:750}.nav-action span{color:var(--accent)}.hero{position:relative;z-index:1;display:grid;grid-template-columns:minmax(0,1.18fr) minmax(330px,.82fr);gap:70px;align-items:center;padding-block:112px 88px}.eyebrow{margin:0 0 15px;color:var(--accent);font-size:.72rem;font-weight:850;letter-spacing:.17em;text-transform:uppercase}.pulse{display:inline-block;width:7px;height:7px;margin-right:8px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 6px rgba(129,244,193,.09);animation:pulse 2s infinite}.hero h1,.article-title h1,.status-title h1{margin:0;font-size:clamp(3.4rem,7.6vw,6.7rem);line-height:.91;letter-spacing:-.065em;font-weight:720}.hero h1 em,.article-title h1 em,.status-title h1 em{color:var(--accent);font-style:normal;font-weight:450}.lead{max-width:650px;margin:30px 0;color:#adbec0;font-size:1.1rem;line-height:1.75}.hero-actions{display:flex;gap:12px;margin-top:30px}.button,button{display:inline-flex;align-items:center;justify-content:center;min-height:48px;padding:0 21px;border:0;border-radius:12px;background:var(--accent);color:var(--ink);font:inherit;font-weight:850;text-decoration:none;cursor:pointer;transition:transform .2s,filter .2s}button:hover,.button:hover{transform:translateY(-2px);filter:brightness(1.04)}button:disabled{opacity:.6;cursor:wait;transform:none}.ghost{border:1px solid var(--line2);background:rgba(255,255,255,.025);color:var(--text)}.trust-row{display:flex;flex-wrap:wrap;gap:22px;margin-top:28px;color:var(--muted);font-size:.76rem}.trust-row span:before{content:"✓";margin-right:6px;color:var(--accent)}.signal-card{min-height:480px;padding:25px;border:1px solid var(--line);border-radius:28px;background:linear-gradient(145deg,rgba(16,36,49,.9),rgba(9,23,33,.9));box-shadow:var(--shadow);backdrop-filter:blur(12px)}.signal-head,.signal-foot{display:flex;justify-content:space-between;gap:20px}.signal-head>span:first-child{font-size:.76rem;color:var(--muted);letter-spacing:.1em;text-transform:uppercase}.status{display:inline-flex;align-items:center;gap:8px;color:var(--muted);font-size:.76rem;font-weight:750}.status i{width:7px;height:7px;border-radius:50%;background:currentColor}.status.good{color:var(--accent)}.status.bad{color:var(--danger)}.orbital{position:relative;width:285px;height:285px;margin:36px auto;display:grid;place-items:center}.orbit{position:absolute;border:1px solid rgba(129,244,193,.18);border-radius:50%}.orbit-one{inset:10px;border-style:dashed;animation:spin 28s linear infinite}.orbit-two{inset:42px;border-color:rgba(93,199,255,.22);animation:spin 18s linear infinite reverse}.orbit:after{content:"";position:absolute;width:9px;height:9px;top:20px;left:50%;border-radius:50%;background:var(--accent);box-shadow:0 0 18px var(--accent)}.core{width:150px;height:150px;display:flex;flex-direction:column;align-items:center;justify-content:center;border:1px solid var(--line2);border-radius:50%;background:radial-gradient(circle,rgba(129,244,193,.09),transparent 70%)}.core span{font-size:3.3rem;line-height:1;font-weight:720;letter-spacing:-.06em}.core small{margin-top:8px;color:var(--muted);font-size:.68rem;text-transform:uppercase;letter-spacing:.1em}.signal-foot{padding-top:19px;border-top:1px solid var(--line)}.signal-foot span{min-width:0}.signal-foot small,.metric-strip small{display:block;color:var(--muted);font-size:.68rem;text-transform:uppercase;letter-spacing:.08em}.signal-foot strong{display:block;max-width:190px;margin-top:4px;overflow:hidden;text-overflow:ellipsis;font-size:.83rem}.metric-strip{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid var(--line);border-radius:20px;background:rgba(13,27,38,.76);overflow:hidden}.metric-strip article{display:flex;align-items:center;gap:14px;padding:23px;border-right:1px solid var(--line)}.metric-strip article:last-child{border:0}.metric-icon{display:grid;place-items:center;width:36px;height:36px;border:1px solid var(--line2);border-radius:10px;color:var(--accent)}.metric-strip strong{display:block;margin-top:3px;font-size:.95rem}.workspace{display:grid;grid-template-columns:1.65fr .85fr;gap:20px;padding-block:90px}.chart-card,.checks-card,.report-card{border:1px solid var(--line);border-radius:22px;background:var(--panel);box-shadow:0 20px 60px rgba(0,0,0,.14)}.chart-card{padding:28px}.section-head{display:flex;align-items:flex-start;justify-content:space-between;gap:30px}.section-head h2,.checks-card h2,.report-card h2{margin:0;font-size:1.55rem;letter-spacing:-.035em}.legend{display:flex;align-items:center;gap:7px;color:var(--muted);font-size:.72rem}.legend i{width:7px;height:7px;border-radius:50%;background:var(--accent2)}.timeline{height:210px;display:flex;align-items:flex-end;gap:7px;margin-top:32px;padding:22px 14px 0;border-bottom:1px solid var(--line);background:repeating-linear-gradient(to bottom,transparent 0,transparent 51px,rgba(255,255,255,.035) 52px)}.timeline.compact{height:150px;margin:30px 0 80px}.timeline-bar{position:relative;flex:1;min-width:7px;max-width:32px;height:var(--h);min-height:4px;border-radius:5px 5px 1px 1px;background:linear-gradient(to top,var(--accent2),var(--accent));transform-origin:bottom;animation:grow .6s both}.timeline-bar:hover:after{content:attr(data-value);position:absolute;bottom:calc(100% + 7px);left:50%;transform:translateX(-50%);padding:3px 7px;border:1px solid var(--line2);border-radius:6px;background:var(--bg2);font-size:.66rem;white-space:nowrap}.empty-chart{align-self:center;margin:auto;color:var(--muted);font-size:.78rem}.chart-axis{display:flex;justify-content:space-between;margin-top:8px;color:#60777d;font-size:.65rem;text-transform:uppercase;letter-spacing:.1em}.checks-card{padding:28px}.checks{list-style:none;margin:26px 0 22px;padding:0}.checks li{display:flex;align-items:center;gap:14px;padding:17px 0;border-bottom:1px solid var(--line)}.check-icon{display:grid;place-items:center;flex:0 0 34px;height:34px;border:1px solid var(--line2);border-radius:50%;color:var(--muted);font-size:.72rem}.check-icon.pass{border-color:rgba(129,244,193,.45);background:rgba(129,244,193,.07);color:var(--accent)}.check-icon.fail{border-color:rgba(255,141,141,.45);color:var(--danger)}.checks strong,.checks small{display:block}.checks strong{font-size:.87rem}.checks small{color:var(--muted);font-size:.73rem}.text-link{display:flex;justify-content:space-between;color:var(--text);text-decoration:none;font-size:.8rem;font-weight:750}.text-link span{color:var(--accent)}.principles{padding-bottom:112px}.principles>.section-head{padding-bottom:32px;border-bottom:1px solid var(--line)}.principles>.section-head h2{max-width:580px;font-size:clamp(2.2rem,4vw,3.6rem);line-height:1.05}.principles>.section-head>p{max-width:390px;margin:20px 0 0;color:var(--muted)}.feature-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;margin-top:28px}.feature-grid article{padding:25px;border:1px solid var(--line);border-radius:18px;background:linear-gradient(145deg,rgba(16,36,49,.58),rgba(8,20,29,.58))}.feature-grid b{color:var(--accent);font-size:.69rem;letter-spacing:.1em}.feature-grid h3{margin:30px 0 8px;font-size:1.05rem}.feature-grid p{margin:0;color:var(--muted);font-size:.84rem}footer{position:relative;border-top:1px solid var(--line);background:#060d13;color:var(--muted)}.footer-grid{display:grid;grid-template-columns:2fr 1fr 1fr;gap:80px;padding-block:55px}.footer-grid>div{display:flex;flex-direction:column;align-items:flex-start;gap:7px}.footer-grid p{max-width:300px}.footer-grid strong{margin-bottom:7px;color:var(--text);font-size:.74rem;text-transform:uppercase;letter-spacing:.1em}.footer-grid a:not(.brand){color:var(--muted);text-decoration:none}.footer-bottom{display:flex;justify-content:space-between;padding-block:20px;border-top:1px solid #172731;font-size:.72rem}.footer-bottom a{color:var(--muted)}.article-shell{display:grid;grid-template-columns:1fr 1fr;gap:110px;padding-block:105px}.article-title{position:sticky;top:55px;align-self:start}.article-title h1{font-size:clamp(3.1rem,6vw,5.8rem)}.article-title>p:last-child{max-width:520px;color:var(--muted);font-size:1rem}.prose{max-width:680px}.prose h2{margin:48px 0 12px;font-size:1.45rem}.prose h2:first-child{margin-top:0}.prose p{color:#adbdc0}.prose code{padding:2px 6px;border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--accent)}.callout{margin:38px 0;padding:22px;border-left:2px solid var(--accent);background:rgba(129,244,193,.055)}.callout p{margin-bottom:0}.status-page{padding-block:85px}.status-title{display:grid;grid-template-columns:1fr auto;align-items:end;margin-bottom:55px}.status-title h1{grid-column:1;font-size:clamp(3.3rem,7vw,6.2rem)}.status-title>p:last-of-type{grid-column:1;max-width:570px;color:var(--muted)}.status-title button{grid-column:2;grid-row:1/4}.status-banner{display:flex;justify-content:space-between;align-items:center;padding:34px;border:1px solid var(--line2);border-radius:24px;background:linear-gradient(120deg,rgba(129,244,193,.07),rgba(93,199,255,.06))}.status-banner h2{margin:15px 0 3px;font-size:1.7rem}.status-banner p{margin:0;color:var(--muted)}.banner-metric{text-align:right}.banner-metric strong{display:block;font-size:3.7rem;line-height:1;letter-spacing:-.06em}.banner-metric span{color:var(--muted);font-size:.7rem;text-transform:uppercase;letter-spacing:.1em}.component-list{margin:24px 0}.component-list article{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:17px;padding:24px;border-bottom:1px solid var(--line)}.component-list h3,.component-list p{margin:0}.component-list h3{font-size:.98rem}.component-list p{color:var(--muted);font-size:.78rem}.component-list>article>strong{font-size:.83rem}.component-dot{width:10px;height:10px;border-radius:50%;background:#52666c}.component-dot.pass{background:var(--accent);box-shadow:0 0 0 6px rgba(129,244,193,.08)}.component-dot.fail{background:var(--danger)}.report-card{display:grid;grid-template-columns:1fr 2fr auto;align-items:center;gap:30px;padding:28px}.report-card dl{display:grid;grid-template-columns:repeat(3,1fr);gap:25px;margin:0}.report-card dl div{border-left:1px solid var(--line);padding-left:20px}.report-card dt{color:var(--muted);font-size:.68rem;text-transform:uppercase;letter-spacing:.08em}.report-card dd{margin:5px 0 0;font-weight:750}.error-page{width:min(720px,calc(100% - 40px));min-height:100vh;margin:auto;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center}.error-page h1{margin:0;font-size:clamp(3rem,8vw,6rem);line-height:.95;letter-spacing:-.06em}.error-page>p:not(.eyebrow){color:var(--muted)}.error-orbit{width:180px;height:180px;margin-bottom:30px;display:grid;place-items:center;border:1px dashed var(--line2);border-radius:50%;animation:spin 30s linear infinite}.error-orbit span{display:grid;place-items:center;width:105px;height:105px;border:1px solid var(--line);border-radius:50%;color:var(--accent);font-size:1.3rem;animation:spin 30s linear infinite reverse}@keyframes pulse{50%{opacity:.45;box-shadow:0 0 0 10px rgba(129,244,193,0)}}@keyframes spin{to{transform:rotate(360deg)}}@keyframes grow{from{transform:scaleY(0)}}@media(max-width:900px){.hero{grid-template-columns:1fr;gap:48px;padding-top:75px}.signal-card{min-height:auto}.metric-strip{grid-template-columns:1fr 1fr}.metric-strip article:nth-child(2){border-right:0}.metric-strip article:nth-child(-n+2){border-bottom:1px solid var(--line)}.workspace{grid-template-columns:1fr}.article-shell{grid-template-columns:1fr;gap:45px}.article-title{position:static}.status-title{display:block}.status-title button{margin-top:20px}.report-card{grid-template-columns:1fr}.report-card dl{order:2}.report-card button{order:3}.feature-grid{grid-template-columns:1fr}.footer-grid{grid-template-columns:1fr 1fr}.footer-grid>div:first-child{grid-column:1/-1}}@media(max-width:640px){.wrap{width:min(100% - 28px,1180px)}.nav{height:70px}.nav nav,.nav-action{display:none}.hero{padding-block:60px}.hero h1{font-size:clamp(3rem,16vw,4.5rem)}.hero-actions{align-items:stretch;flex-direction:column}.signal-card{padding:20px}.orbital{width:245px;height:245px}.metric-strip{grid-template-columns:1fr}.metric-strip article{border-right:0;border-bottom:1px solid var(--line)}.metric-strip article:nth-child(2){border-bottom:1px solid var(--line)}.workspace{padding-block:60px}.section-head{display:block}.legend{margin-top:10px}.principles>.section-head>p{max-width:none}.footer-grid{grid-template-columns:1fr;gap:30px}.footer-grid>div:first-child{grid-column:auto}.footer-bottom{gap:20px}.status-page{padding-block:55px}.status-banner{align-items:flex-start;gap:30px}.banner-metric strong{font-size:2.5rem}.component-list article{grid-template-columns:auto 1fr}.component-list>article>strong{grid-column:2}.report-card dl{grid-template-columns:1fr}.report-card dl div{border-left:0;border-top:1px solid var(--line);padding:10px 0 0}.article-shell{padding-block:65px}}
EOF
    cat >"${INSTALL_DIR}/site/diagnostics.js" <<'EOF'
(()=>{'use strict';const report={},history=[],$=id=>document.getElementById(id),all=s=>[...document.querySelectorAll(s)];function set(id,value){const node=$(id);if(node)node.textContent=value;report[id]=value}function mark(name,state){all(`[data-check="${name}"]`).forEach(node=>{node.classList.remove('pass','fail');if(state)node.classList.add(state)})}function localState(){const online=navigator.onLine;set('host',location.hostname);set('online',online?'Online':'Offline');set('secure',isSecureContext?'Verified HTTPS':'Not secure');set('dnsState',location.hostname?'Origin hostname available':'Hostname unavailable');set('tlsState',isSecureContext?'Secure browser context':'Secure context unavailable');mark('dns',location.hostname?'pass':'fail');mark('tls',isSecureContext?'pass':'fail')}function draw(samples){const root=$('timeline');if(!root)return;root.replaceChildren();samples.forEach((sample,index)=>{const bar=document.createElement('span');const max=Math.max(...samples,1);bar.className='timeline-bar';bar.style.setProperty('--h',`${Math.max(5,Math.round(sample/max*100))}%`);bar.style.animationDelay=`${index*55}ms`;bar.dataset.value=`${Math.round(sample)} ms`;root.append(bar)})}function status(text,state){const node=$('result');if(!node)return;node.className=`status ${state||''}`;node.replaceChildren();const dot=document.createElement('i');node.append(dot,document.createTextNode(text))}async function run(){const button=$('run');if(button)button.disabled=true;status('Running checks');set('httpState','Collecting seven fresh samples');const samples=[];try{for(let i=0;i<7;i++){const start=performance.now();const response=await fetch(`/health.txt?probe=${Date.now()}-${i}`,{cache:'no-store',credentials:'same-origin'});if(!response.ok)throw new Error(`HTTP ${response.status}`);const body=(await response.text()).trim();if(body!=='ok')throw new Error('Unexpected health response');samples.push(performance.now()-start)}const ordered=[...samples].sort((a,b)=>a-b),median=ordered[Math.floor(ordered.length/2)],jitter=ordered.reduce((sum,value)=>sum+Math.abs(value-median),0)/ordered.length,slowest=ordered.at(-1);history.push(...samples);if(history.length>28)history.splice(0,history.length-28);set('latency',`${Math.round(median)} ms`);set('latencyBig',String(Math.round(median)));set('jitter',`${Math.round(jitter)} ms`);set('checked',new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'}));set('httpState',`7/7 responses · slowest ${Math.round(slowest)} ms`);set('bannerTitle','Endpoint is reachable');set('bannerText','All same-origin browser checks completed successfully.');status('Operational','good');mark('http','pass');draw(history)}catch(error){set('latency','Unavailable');set('latencyBig','—');set('jitter','Unavailable');set('checked',new Date().toLocaleTimeString());set('httpState',`Check failed · ${error.message}`);set('bannerTitle','Endpoint check failed');set('bannerText','The browser could not complete the same-origin health request.');status('Unavailable','bad');mark('http','fail')}finally{if(button)button.disabled=false}}async function copy(){const button=$('copy'),text=['Northstar endpoint report',`origin: ${location.origin}`,...Object.entries(report).map(([key,value])=>`${key}: ${value}`)].join('\n');try{await navigator.clipboard.writeText(text);button.textContent='Copied to clipboard'}catch{button.textContent='Copy unavailable'}}const runButton=$('run'),copyButton=$('copy');if(runButton)runButton.addEventListener('click',run);if(copyButton)copyButton.addEventListener('click',copy);addEventListener('online',localState);addEventListener('offline',localState);document.addEventListener('visibilitychange',()=>{if(!document.hidden&&history.length)run()});set('year',String(new Date().getFullYear()));localState();run()})();
EOF
    cat >"${INSTALL_DIR}/site/favicon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="17" fill="#0d1b26"/><circle cx="32" cy="32" r="20" fill="none" stroke="#274653"/><path d="M17 44V20l30 24V20" fill="none" stroke="#81f4c1" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/><circle cx="47" cy="20" r="4" fill="#5dc7ff"/></svg>
EOF
    cat >"${INSTALL_DIR}/site/site.webmanifest" <<'EOF'
{"name":"Northstar Edge Observatory","short_name":"Northstar","start_url":"/","display":"standalone","background_color":"#071018","theme_color":"#071018","icons":[{"src":"/favicon.svg","sizes":"any","type":"image/svg+xml"}]}
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
    local node_memory
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
    # Relative weight applies only during contention; no CFS quota prevents
    # short throughput bursts from using every vCPU exposed by the VM.
    cpu_shares: 2048
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
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        cat >>"${INSTALL_DIR}/docker-compose.node.yml" <<EOF
    volumes:
      - caddy_data:${CADDY_DATA_CONTAINER_DIR}:ro
EOF
        # Upgrade bridge only: an existing 2026-08-13.9 installation may still
        # be running the old Panel profile until the operator pastes the newly
        # generated one. Keep that already-existing bind readable during the
        # migration; fresh installations never create this directory.
        if [[ -d "${PRIVATE_DIR}/hysteria-tls" ]]; then
            cat >>"${INSTALL_DIR}/docker-compose.node.yml" <<EOF
      - ./private/hysteria-tls:/etc/remnawave-edge/hysteria-tls:ro
EOF
        fi
        cat >>"${INSTALL_DIR}/docker-compose.node.yml" <<EOF

volumes:
  caddy_data:
    external: true
    name: ${COMPOSE_PROJECT}-caddy-data
EOF
    fi

    cat >"${INSTALL_DIR}/docker-compose.edge.yml" <<EOF
name: ${COMPOSE_PROJECT}
services:
  caddy:
    image: ${CADDY_IMAGE}
    pull_policy: never
    container_name: ${CADDY_CONTAINER}
    network_mode: host
    restart: unless-stopped
    cpu_shares: 512
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
    cpu_shares: 1024
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
    # inbound.  Use the singular fragment fields shared by Xray 26.5.9 and
    # 26.6.27: plural `lengths`/`delays` makes Happ's older core decode an empty
    # `length` and fail with "LengthMin can't be 0".
    cat >"${INSTALL_DIR}/finalmask-fragment-canary.json" <<'EOF'
{
  "tcp": [
    {
      "type": "fragment",
      "settings": {
        "packets": "tlshello",
        "length": "10-20",
        "delay": "0-2",
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
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
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
6. The template sends Russian services, selected game ports and detected
   BitTorrent DIRECT from the client. Those destinations see the client's real
   public IP. Remove the DIRECT rules if a squad requires strict full-tunnel
   privacy instead of local-RU reachability and latency.
EOF
    chmod 0600 "${PRIVATE_DIR}/SUBSCRIPTION-SETTINGS.txt"
}

render_auto_template() {
    local remark_pattern="^RW ${NODE_CODE} (REALITY|XHTTP|HY2)( |$)"
    local output="${PRIVATE_DIR}/xray-json-auto.template.json"
    cat >"${output}" <<EOF
{
  "remnawave": {
    "injectHosts": [
      {
        "selector": {
          "type": "remarkRegex",
          "pattern": "${remark_pattern}"
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
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "direct"},
      {
        "type": "field",
        "network": "tcp,udp",
        "port": "27015-27059,3478,4379-4380",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ru",
          "geosite:steam",
          "geosite:twitch",
          "geosite:apple",
          "geosite:xiaomi",
          "geosite:huawei",
          "geosite:category-android-app-download",
          "geosite:mailru-group",
          "geosite:yandex",
          "geosite:wildberries",
          "geosite:ozon",
          "geosite:avito",
          "geosite:x5",
          "domain:2gis.com",
          "domain:2gis.ae",
          "domain:2gis.kz",
          "domain:2gis.uz",
          "domain:vk.com",
          "domain:userapi.com",
          "domain:vk-cdn.net",
          "domain:vkuser.net",
          "domain:vkuservideo.net",
          "domain:mycdn.me",
          "domain:yandex.com",
          "domain:yandex.net",
          "domain:yandexcloud.net",
          "domain:yastatic.net",
          "domain:sberbank.com",
          "domain:tinkoff-group.com",
          "domain:tinkoff.cloud",
          "domain:ozon.com",
          "domain:ozonusercontent.com",
          "domain:wildberries.com",
          "domain:wbcontent.net",
          "domain:wbstatic.net",
          "domain:avito.st",
          "domain:samokat.tech",
          "domain:ecom.tech",
          "domain:goldapple.by",
          "domain:goldapple.kz",
          "domain:goldapple.ae",
          "domain:goldapple.sa",
          "domain:goldapple.qa",
          "domain:megamarket.tech",
          "domain:kuper.tech",
          "domain:x5.tech"
        ],
        "outboundTag": "direct"
      },
      {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
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
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
EOF
    if [[ "${BLOCK_CLIENT_QUIC}" == 1 ]]; then
        jq '.routing.rules |=
          (.[0:3] + [{type:"field", network:"udp", port:443, outboundTag:"block"}] + .[3:])' \
            "${output}" >"${output}.tmp"
        mv -f "${output}.tmp" "${output}"
    fi
    chmod 0600 "${output}"
    install -m 0600 "${output}" "${PRIVATE_DIR}/xray-json-auto.ready.json"
}

selected_primary_inbound_tag() {
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then printf '%s' "${RAW_TAG}"
    elif [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then printf '%s' "${EXTERNAL_REALITY_TAG}"
    elif [[ "${ENABLE_XHTTP}" == 1 ]]; then printf '%s' "${XHTTP_TAG}"
    else printf '%s' "${HYSTERIA_TAG}"
    fi
}

selected_inbound_tags_csv() {
    local value=''
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || value+="${value:+, }${RAW_TAG}"
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || value+="${value:+, }${EXTERNAL_REALITY_TAG}"
    [[ "${ENABLE_XHTTP}" != 1 ]] || value+="${value:+, }${XHTTP_TAG}"
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || value+="${value:+, }${HYSTERIA_TAG}"
    printf '%s' "${value}"
}

render_panel_stage_one() {
    local active_inbounds primary_tag self_section='' external_section=''
    local xhttp_section='' hysteria_section='' fragment_section='' migration_note=''
    local base_tag base_name base_sni_line
    active_inbounds="$(selected_inbound_tags_csv)"
    primary_tag="$(selected_primary_inbound_tag)"
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        self_section="
PHYSICAL HOST — RAW/TCP REALITY SELF-SNI
   Remark: RW ${NODE_CODE} REALITY SELF FF
   Inbound: ${RAW_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Leave SNI, Host, Path, ALPN, Security Layer, Mux, SockOpt, FinalMask and
   Vless Route ID empty/default. Panel inherits self-SNI, key and shortId.
   Host Visibility: ON
   Hide Host: ON
   Exclude formats: XRAY_JSON
   Tag: ${NODE_CODE}:REALITY:SELF (administrative only)
   Nodes: optional visual metadata"
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        external_section="
PHYSICAL HOST — RAW/TCP REALITY EXTERNAL TARGET
   Remark: RW ${NODE_CODE} REALITY EXT FF
   Inbound: ${EXTERNAL_REALITY_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> SNI: ${EXTERNAL_REALITY_SNI}
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Leave Host, Path, ALPN, Security Layer, Mux, SockOpt, FinalMask and
   Vless Route ID empty/default. Panel inherits the dedicated key and shortId.
   Host Visibility: ON
   Hide Host: ON
   Exclude formats: XRAY_JSON
   Tag: ${NODE_CODE}:REALITY:EXTERNAL (administrative only)
   Nodes: optional visual metadata

   Measured target at init: ${EXTERNAL_REALITY_TARGET}
   Re-run init/verify after target DNS, certificate or reachability changes."
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        xhttp_section="
PHYSICAL HOST — VLESS XHTTP / TLS
   Remark: RW ${NODE_CODE} XHTTP FF
   Inbound: ${XHTTP_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> SNI: ${XHTTP_SNI}
   Advanced -> Host: ${XHTTP_SNI}
   Advanced -> Security Layer: TLS
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Advanced -> ALPN: h2
   Leave Path empty: Panel inherits the generated trailing-slash path and
   auto mode. Leave XHTTP Extra, Mux, SockOpt and FinalMask empty.
   Host Visibility: ON
   Hide Host: ON
   Exclude formats: XRAY_JSON
   Tag: ${NODE_CODE}:XHTTP (administrative only)
   Nodes: optional visual metadata"
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        hysteria_section="
PHYSICAL HOST — HYSTERIA2 / UDP 443
   Remark: RW ${NODE_CODE} HY2
   Inbound: ${HYSTERIA_TAG}
   Address: ${EDGE_IPV4}
   Port: 443
   Advanced -> SNI: leave empty (inherits ${XHTTP_SNI} from the inbound)
   Advanced -> Security Layer: TLS
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Advanced -> ALPN: h3
   Advanced -> Pinned Peer Certificate SHA256: leave empty
   Leave Host, Path, Mux, SockOpt and FinalMask empty/default. Caddy supplies
   a publicly trusted Let's Encrypt certificate, so allowInsecure and pinning
   must remain disabled.
   Host Visibility: ON
   Hide Host: ON
   Exclude formats: XRAY_JSON
   Tag: ${NODE_CODE}:HY2 (administrative only)
   Nodes: optional visual metadata

   Do not enable allowInsecure. UDP hopping and Salamander stay off."
        if [[ -d "${PRIVATE_DIR}/hysteria-tls" ]]; then
            migration_note="
UPGRADE FROM THE LEGACY SELF-SIGNED HY2 BUILD
   Do not save the new Config Profile first. Run the node stage once while the
   old profile is still active; it mounts both the old compatibility directory
   and Caddy storage, so current sessions can recover after recreation. Then
   replace the Config Profile with config-profile.ready.json, wait for Node/Xray
   to return online, clear the Host certificate pin, refresh the subscription,
   and run verify plus verify-auth. The old directory is no longer referenced
   by the new profile and may be removed only after that canary succeeds."
        fi
    fi
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        if [[ "${FRAGMENT_REALITY}" == external ]]; then
            base_tag="${EXTERNAL_REALITY_TAG}"; base_name='EXTERNAL'
            base_sni_line="Advanced -> SNI: ${EXTERNAL_REALITY_SNI}"
        else
            base_tag="${RAW_TAG}"; base_name='SELF'
            base_sni_line='Advanced -> SNI: leave empty (inherit from inbound)'
        fi
        fragment_section="
PHYSICAL HOST — REALITY ${base_name} / CLIENT FRAGMENT A/B
   This is another Host for the same inbound, not another listener.
   Remark: RW ${NODE_CODE} REALITY ${base_name} FRAGMENT
   Inbound: ${base_tag}
   Address: ${EDGE_IPV4}
   Port: 443
   ${base_sni_line}
   Advanced -> Fingerprint: ${CLIENT_FINGERPRINT}
   Advanced -> FinalMask: paste the whole object from:
     ${INSTALL_DIR}/finalmask-fragment-canary.json
   Leave all other overrides empty/default.
   Host Visibility: ON
   Hide Host: ON
   Exclude formats: XRAY_JSON
   Tag: ${NODE_CODE}:REALITY:${base_name}:FRAGMENT (administrative only)

   FinalMask is client-side only. Never paste it into the server profile."
    fi
    cat >"${PRIVATE_DIR}/PANEL-STAGE-1.txt" <<EOF
REMNAWAVE PANEL 2.8.1 — STAGE 1
================================
${migration_note}

1. CONFIG PROFILE
   Config Profiles -> Create
   Name: ${PROFILE_NAME}
   Paste the whole protected file:
   ${PRIVATE_DIR}/config-profile.ready.json

   Selected managed inbound tags: ${active_inbounds}

2. NODE
   Internal name: RW-${NODE_CODE}
   Country: actual server country
   Address: ${EDGE_IPV4}
   Port: ${NODE_PORT}
   Config Profile: ${PROFILE_NAME}
   Active Inbounds: ${active_inbounds}
   Plugin: None / disabled
   Tags: ${NODE_CODE}:EDGE (administrative only)
   Traffic multipliers: 1.0 / 1.0

   Save, copy the newly issued SECRET_KEY, then run:
   sudo bash <this-script> node

3. ACCESS AFTER NODE IS ONLINE
   Create Internal Squad RW-${NODE_CODE}-CANARY.
   Attach exactly: ${active_inbounds}
   Add one ACTIVE canary user. Keep HWID off for the first test.

4. CREATE ONLY THE SELECTED PHYSICAL HOSTS
${self_section}
${external_section}
${fragment_section}
${xhttp_section}
${hysteria_section}

Save every physical Host, then run: sudo bash <this-script> template

For every physical Host, XRAY_JSON exclusion is mandatory even though the Host
is hidden. Backend 2.8.1 still allows the injector to consume a hidden,
XRAY_JSON-excluded Host; the exclusion prevents accidental standalone JSON
output if visibility is changed later. Exclusion is a Host field, not an
inbound field.

Do not type a public key, shortId, flow or public id into a Host. Remnawave
2.8.1 derives those values from the selected managed inbound.

The later AUTO carrier Host must bind to: ${primary_tag}
EOF
    chmod 0600 "${PRIVATE_DIR}/PANEL-STAGE-1.txt"
}

render_panel_stage_two() {
    local primary_tag physical_count=0
    primary_tag="$(selected_primary_inbound_tag)"
    ((physical_count += ENABLE_SELF_REALITY + ENABLE_EXTERNAL_REALITY + ENABLE_XHTTP + ENABLE_HYSTERIA))
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || ((physical_count += 1))
    cat >"${PRIVATE_DIR}/PANEL-STAGE-2.txt" <<EOF
REMNAWAVE PANEL 2.8.1 — STAGE 2
================================

The AUTO template selects hidden physical Hosts whose Remark starts with
"RW ${NODE_CODE} REALITY", "RW ${NODE_CODE} XHTTP" or "RW ${NODE_CODE} HY2".
No Host UUID input is required.

1. XRAY_JSON TEMPLATE
   Create template: RW-${NODE_CODE}-AUTO
   Paste the whole strict JSON file:
   ${PRIVATE_DIR}/xray-json-auto.ready.json

2. AUTO CARRIER HOST
   Panel requires an inbound even though this Host only selects the template.
   Remark: RW ${NODE_CODE} AUTO
   Inbound: ${primary_tag}
   Address: ${EDGE_IPV4}
   Port: 443
   Xray JSON Template: RW-${NODE_CODE}-AUTO
   Advanced overrides: all empty/default
   Host Visibility: ON
   Hide Host: OFF
   Tag: ${NODE_CODE}:AUTO (administrative only)
   Exclude formats: every format except XRAY_JSON
   Keep production squads excluded during canary.

   AUTO is visible, so it cannot match the hidden-only injector. Expected match
   count: ${physical_count}. Do not reuse this exact Remark prefix for unrelated
   hidden Hosts.

3. SUBSCRIPTION
   Enable Serve JSON at base subscription. Keep built-in Response Rules and
   happRouting unchanged. Happ/INCY users only press Refresh/Update.

4. TEST
   Run edge, verify and verify-auth. Test every selected transport separately,
   then AUTO in Happ/INCY TUN before expanding beyond the canary squad.
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
    local template="$1" temp_dir test_uuid config tmp tag index=1
    temp_dir="$(mktemp -d)"
    config="${temp_dir}/client.json"
    tmp="${temp_dir}/next.json"
    test_uuid="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" uuid | tr -d '\r\n')"
    jq 'del(.remnawave) | .outbounds = []' "${template}" >"${config}"
    append_reality_test() {
        local public_key="$1" short_id="$2" server_name="$3"
        if ((index == 1)); then tag='proxy'; else tag="proxy-${index}"; fi
        jq --arg tag "${tag}" --arg uuid "${test_uuid}" --arg public_key "${public_key}" \
            --arg short_id "${short_id}" --arg server_name "${server_name}" \
            --arg fingerprint "${CLIENT_FINGERPRINT}" '
          .outbounds += [{
            tag: $tag, protocol: "vless",
            settings: {vnext: [{address: "127.0.0.1", port: 10443,
              users: [{id: $uuid, encryption: "none", flow: "xtls-rprx-vision"}]}]},
            streamSettings: {network: "raw", security: "reality", realitySettings: {
              fingerprint: $fingerprint, serverName: $server_name,
              publicKey: $public_key, shortId: $short_id, spiderX: "/"
            }}
          }]
        ' "${config}" >"${tmp}"
        mv -f "${tmp}" "${config}"
        index=$((index + 1))
    }
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        append_reality_test "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}" 'reality.example.com'
        [[ "${ENABLE_RAW_FRAGMENT}" != 1 || "${FRAGMENT_REALITY}" != self ]] || \
            append_reality_test "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}" 'reality.example.com'
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        append_reality_test "${EXTERNAL_REALITY_PUBLIC_KEY}" "${EXTERNAL_REALITY_SHORT_ID}" \
            "${EXTERNAL_REALITY_SNI}"
        [[ "${ENABLE_RAW_FRAGMENT}" != 1 || "${FRAGMENT_REALITY}" != external ]] || \
            append_reality_test "${EXTERNAL_REALITY_PUBLIC_KEY}" "${EXTERNAL_REALITY_SHORT_ID}" \
                "${EXTERNAL_REALITY_SNI}"
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        if ((index == 1)); then tag='proxy'; else tag="proxy-${index}"; fi
        jq --arg tag "${tag}" --arg uuid "${test_uuid}" --arg fingerprint "${CLIENT_FINGERPRINT}" '
          .outbounds += [{
            tag: $tag, protocol: "vless",
            settings: {vnext: [{address: "127.0.0.1", port: 10443,
              users: [{id: $uuid, encryption: "none"}]}]},
            streamSettings: {network: "xhttp", security: "tls",
              tlsSettings: {serverName: "xhttp.example.net", fingerprint: $fingerprint, alpn: ["h2"]},
              xhttpSettings: {host: "xhttp.example.net", path: "/api/v1/test/", mode: "auto"}}
          }]
        ' "${config}" >"${tmp}"
        mv -f "${tmp}" "${config}"
        index=$((index + 1))
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        if ((index == 1)); then tag='proxy'; else tag="proxy-${index}"; fi
        jq --arg tag "${tag}" --arg uuid "${test_uuid}" \
            --arg server_name "${XHTTP_SNI}" --arg fingerprint "${CLIENT_FINGERPRINT}" '
          .outbounds += [{
            tag: $tag, protocol: "hysteria", settings: {address: "127.0.0.1", port: 443, version: 2},
            streamSettings: {network: "hysteria", security: "tls",
              tlsSettings: {serverName: $server_name, fingerprint: $fingerprint,
                alpn: ["h3"]},
              hysteriaSettings: {version: 2, auth: $uuid}}
          }]
        ' "${config}" >"${tmp}"
        mv -f "${tmp}" "${config}"
    fi
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
        -v "${config}:/etc/xray/config.json:ro" --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -test -config /etc/xray/config.json >/dev/null
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        jq --slurpfile fm "${INSTALL_DIR}/finalmask-fragment-canary.json" '
          (.outbounds[] | select(.streamSettings.network == "raw") | .streamSettings.finalmask) = $fm[0]
        ' "${config}" >"${tmp}"
        docker run --rm --pull never --network none --cap-drop ALL --read-only \
            -v "${tmp}:/etc/xray/config.json:ro" --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
            run -test -config /etc/xray/config.json >/dev/null
    fi
    unset -f append_reality_test
    find "${temp_dir}" -depth -delete
}

validate_artifacts() {
    local caddy_output caddy_json node_compose_json edge_compose_json xray_validation_config=''
    local expected_inbounds=0 expected_hosts=0 site_bytes required_site_file
    local -a caddy_subjects=("${REALITY_SNI}") xray_server_mounts=() material=()
    log 'Validating strict JSON, pinned Xray, Compose, HAProxy and Caddy...'
    jq empty "${PRIVATE_DIR}/config-profile.ready.json"
    jq empty "${PRIVATE_DIR}/xray-json-auto.template.json"
    jq empty "${INSTALL_DIR}/finalmask-fragment-canary.json"
    jq -e '
      (.tcp | type == "array" and length == 1) and
      (.tcp[0].type == "fragment") and
      (.tcp[0].settings |
        .packets == "tlshello" and
        (.length | type == "string" and length > 0) and
        (.delay | type == "string" and length > 0) and
        (has("lengths") | not) and (has("delays") | not))
    ' "${INSTALL_DIR}/finalmask-fragment-canary.json" >/dev/null ||
        die 'FinalMask fragment must use the Happ-compatible singular length/delay schema.'
    [[ ! -f "${PRIVATE_DIR}/xray-json-auto.ready.json" ]] || \
        jq empty "${PRIVATE_DIR}/xray-json-auto.ready.json"

    for required_site_file in index.html status.html about.html 404.html \
      site.css diagnostics.js favicon.svg site.webmanifest health.txt robots.txt; do
        [[ -s "${INSTALL_DIR}/site/${required_site_file}" ]] || \
            die "Cover site is missing ${required_site_file}."
    done
    site_bytes="$(du -sb "${INSTALL_DIR}/site" | awk '{print $1}')"
    [[ "${site_bytes}" =~ ^[0-9]+$ ]] || die 'Could not measure cover-site payload.'
    ((site_bytes <= 41943040)) || die 'Cover-site payload exceeds the 40 MiB budget.'
    if grep -RIE "<(script|link|img)[^>]+(src|href)=[\"']https?://" \
      "${INSTALL_DIR}/site" >/dev/null; then
        die 'Cover site must not load third-party scripts, styles or images.'
    fi

    ((expected_inbounds += ENABLE_SELF_REALITY + ENABLE_EXTERNAL_REALITY + ENABLE_XHTTP + ENABLE_HYSTERIA))
    ((expected_hosts += ENABLE_SELF_REALITY + ENABLE_EXTERNAL_REALITY + ENABLE_XHTTP + ENABLE_HYSTERIA))
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || ((expected_hosts += 1))
    jq -e --argjson expected "${expected_inbounds}" '
      (.inbounds | length == $expected) and
      (all(.inbounds[]; (.settings | has("flow") | not))) and
      (all(.inbounds[]; (.streamSettings | has("finalmask") | not)))
    ' "${PRIVATE_DIR}/config-profile.ready.json" >/dev/null || \
        die 'Server profile has an unexpected inbound count, manual flow, or server FinalMask.'

    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        jq -e --arg tag "${RAW_TAG}" --arg sni "${REALITY_SNI}" \
          --arg target "127.0.0.1:${CADDY_BACKEND_PORT}" '
          [.inbounds[] | select(
            .tag == $tag and .listen == "127.0.0.1" and
            .streamSettings.network == "raw" and .streamSettings.security == "reality" and
            .streamSettings.sockopt.acceptProxyProtocol == true and
            .streamSettings.realitySettings.target == $target and
            .streamSettings.realitySettings.serverNames == [$sni]
          )] | length == 1
        ' "${PRIVATE_DIR}/config-profile.ready.json" >/dev/null || \
            die 'Self-SNI REALITY inbound lost its loopback, target, SNI, or PROXY contract.'
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        jq -e --arg tag "${EXTERNAL_REALITY_TAG}" --arg sni "${EXTERNAL_REALITY_SNI}" \
          --arg target "${EXTERNAL_REALITY_TARGET}" '
          [.inbounds[] | select(
            .tag == $tag and .listen == "127.0.0.1" and
            .streamSettings.network == "raw" and .streamSettings.security == "reality" and
            .streamSettings.sockopt.acceptProxyProtocol == true and
            .streamSettings.realitySettings.target == $target and
            .streamSettings.realitySettings.serverNames == [$sni] and
            .streamSettings.realitySettings.limitFallbackUpload.bytesPerSec == 1048576 and
            .streamSettings.realitySettings.limitFallbackDownload.bytesPerSec == 1048576
          )] | length == 1
        ' "${PRIVATE_DIR}/config-profile.ready.json" >/dev/null || \
            die 'External-target REALITY inbound lost its loopback, target, SNI, or PROXY contract.'
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        jq -e --arg tag "${XHTTP_TAG}" --arg path "${XHTTP_PATH}" '
          [.inbounds[] | select(
            .tag == $tag and .listen == "127.0.0.1" and
            .streamSettings.network == "xhttp" and .streamSettings.security == "none" and
            .streamSettings.xhttpSettings.mode == "auto" and
            .streamSettings.xhttpSettings.path == $path
          )] | length == 1
        ' "${PRIVATE_DIR}/config-profile.ready.json" >/dev/null || \
            die 'XHTTP inbound lost its loopback, auto-mode, or exact trailing-slash path contract.'
        caddy_subjects+=("${XHTTP_SNI}")
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        jq -e --arg tag "${HYSTERIA_TAG}" --argjson port 443 \
          --arg masq "http://127.0.0.1:${HYSTERIA_MASQ_PORT}" \
          --arg server_name "${XHTTP_SNI}" \
          --arg cert_path "$(hysteria_cert_container_path)" \
          --arg key_path "$(hysteria_key_container_path)" '
          [.inbounds[] | select(
            .tag == $tag and .listen == "0.0.0.0" and .port == $port and
            .protocol == "hysteria" and .settings.version == 2 and
            .streamSettings.security == "tls" and
            .streamSettings.hysteriaSettings.masquerade.url == $masq and
            .streamSettings.tlsSettings.serverName == $server_name and
            .streamSettings.tlsSettings.certificates == [{
              certificateFile: $cert_path, keyFile: $key_path, oneTimeLoading: false
            }] and
            ([.streamSettings.tlsSettings.certificates[] |
              has("certificate") or has("key")] | any | not)
          )] | length == 1
        ' "${PRIVATE_DIR}/config-profile.ready.json" >/dev/null || \
            die 'Hysteria2 inbound lost its UDP/443, Caddy-certificate, SNI, or masquerade contract.'
        if caddy_hysteria_material_paths >/dev/null 2>&1; then
            mapfile -t material < <(caddy_hysteria_material_paths)
            if ((${#material[@]} == 2)) && \
               [[ -s "${material[0]}" && -s "${material[1]}" ]]; then
                xray_server_mounts=(
                    -v "$(caddy_volume_name):${CADDY_DATA_CONTAINER_DIR}:ro"
                )
            fi
        fi
    fi

    [[ "$(grep -Fc 'Exclude formats: XRAY_JSON' "${PRIVATE_DIR}/PANEL-STAGE-1.txt")" \
        == "${expected_hosts}" ]] || \
        die 'Panel guide does not exclude every physical Host from standalone XRAY_JSON output.'

    jq -e '
      .remnawave.injectHosts[0].selectFrom == "HIDDEN" and
      .remnawave.injectHosts[0].selector.type == "remarkRegex" and
      (.remnawave.injectHosts[0].selector.pattern | startswith("^RW ")) and
      .routing.balancers[0].strategy.type == "leastPing" and
      ([.routing.rules[] | select(
        .outboundTag == "direct" and .protocol == ["bittorrent"]
      )] | length == 1) and
      ([.routing.rules[] | select(
        .outboundTag == "direct" and
        .port == "27015-27059,3478,4379-4380"
      )] | length == 1) and
      ([.routing.rules[] | select(
        .outboundTag == "direct" and
        (.domain // [] | index("geosite:category-ru")) != null and
        (.domain // [] | index("domain:samokat.tech")) != null and
        (.domain // [] | index("domain:goldapple.kz")) != null
      )] | length == 1) and
      ([.routing.rules[] | select(
        .outboundTag == "direct" and .ip == ["geoip:ru", "geoip:private"]
      )] | length == 1) and
      ([.outbounds[] | select(
        .tag == "direct" and .protocol == "freedom" and
        .settings.domainStrategy == "UseIPv4"
      )] | length == 1) and
      (.dns.servers | length == 3) and
      (.dns.servers[0].address | startswith("https://")) and
      (.dns.servers[1].address | startswith("https://")) and
      .dns.servers[2].address == "fakedns"
    ' "${PRIVATE_DIR}/xray-json-auto.template.json" >/dev/null || \
        die 'AUTO template lost its selector, DNS, balancing, or RU-direct routing contract.'

    if [[ "${ENABLE_HYSTERIA}" == 1 && ${#xray_server_mounts[@]} -eq 0 ]]; then
        # Before the first public ACME issuance there is deliberately no local
        # fallback certificate. Validate every other inbound now; node_stage
        # obtains and validates the trusted certificate before its final full
        # Xray test and before starting the Node container.
        xray_validation_config="$(mktemp "${PRIVATE_DIR}/.xray-pre-acme.XXXXXX")"
        jq --arg tag "${HYSTERIA_TAG}" 'del(.inbounds[] | select(.tag == $tag))' \
            "${PRIVATE_DIR}/config-profile.ready.json" >"${xray_validation_config}"
    else
        xray_validation_config="${PRIVATE_DIR}/config-profile.ready.json"
    fi
    if ! docker run --rm --pull never --network none --cap-drop ALL --read-only \
        "${xray_server_mounts[@]}" \
        -v "${xray_validation_config}:/etc/xray/config.json:ro" \
        --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
        run -test -config /etc/xray/config.json >/dev/null; then
        [[ "${xray_validation_config}" == "${PRIVATE_DIR}/config-profile.ready.json" ]] || \
            find "${xray_validation_config}" -maxdepth 0 -delete
        die 'Pinned Xray rejected the generated server profile.'
    fi
    [[ "${xray_validation_config}" == "${PRIVATE_DIR}/config-profile.ready.json" ]] || \
        find "${xray_validation_config}" -maxdepth 0 -delete

    validate_auto_template_model "${PRIVATE_DIR}/xray-json-auto.template.json"
    docker compose --env-file "${PRIVATE_DIR}/edge.env" \
        -f "${INSTALL_DIR}/docker-compose.edge.yml" config --quiet
    edge_compose_json="$(docker compose --env-file "${PRIVATE_DIR}/edge.env" \
        -f "${INSTALL_DIR}/docker-compose.edge.yml" config --format json)"
    docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" config --quiet
    node_compose_json="$(docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" \
        config --format json)"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        jq -e --arg target "${CADDY_DATA_CONTAINER_DIR}" \
          --arg volume_name "$(caddy_volume_name)" '
          ([.services.node.volumes[] | select(
            .type == "volume" and .source == "caddy_data" and
            .target == $target and .read_only == true
          )] | length == 1) and
          .volumes.caddy_data.external == true and
          .volumes.caddy_data.name == $volume_name
        ' <<<"${node_compose_json}" >/dev/null || \
            die 'Node Compose lost the read-only Caddy certificate volume.'
    else
        jq -e --arg target "${CADDY_DATA_CONTAINER_DIR}" '
          [(.services.node.volumes // [])[] | select(.target == $target)] | length == 0
        ' <<<"${node_compose_json}" >/dev/null || \
            die 'Node Compose unexpectedly mounts Caddy storage while Hysteria2 is disabled.'
    fi
    jq -e '
      .services.node.cpu_shares == 2048 and
      ((.services.node.cpus // null) == null)
    ' <<<"${node_compose_json}" >/dev/null || \
        die 'Node Compose lost burst CPU policy or regained a hard CPU quota.'
    jq -e '
      .services.haproxy.cpu_shares == 1024 and
      .services.caddy.cpu_shares == 512 and
      ((.services.haproxy.cpus // null) == null) and
      ((.services.caddy.cpus // null) == null)
    ' <<<"${edge_compose_json}" >/dev/null || \
        die 'Edge Compose lost weighted burst CPU policy or regained hard quotas.'

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
    jq -e --argjson subjects "$(printf '%s\n' "${caddy_subjects[@]}" | jq -R . | jq -s .)" '
      ([.apps.tls.automation.policies[].issuers[]?]) as $issuers |
      (($issuers | length) >= 1) and
      (all($issuers[];
        .module == "acme" and
        .ca == "https://acme-v02.api.letsencrypt.org/directory" and
        .challenges.http.disabled == true and
        .challenges."tls-alpn".alternate_port == 19443)) and
      (([.apps.http.servers[].routes[]?.match[]?.host[]? |
          select(. != "127.0.0.1")] | unique | sort) ==
        ($subjects | unique | sort)) and
      ([.apps.http.servers[].listen[]] | index("127.0.0.1:19443") != null) and
      ([.apps.http.servers[].listen[]] | index("0.0.0.0:19443") == null)
    ' <<<"${caddy_json}" >/dev/null || \
        die 'Caddy lost its selected-subject TLS-ALPN or loopback-only listener contract.'
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
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then check_one_domain_dns "${XHTTP_SNI}"; fi
    log 'DNS checks passed.'
}

port_is_listening() {
    [[ -n "$(ss -H -ltn "sport = :$1")" ]]
}

udp_port_is_listening() {
    [[ -n "$(ss -H -lun "sport = :$1")" ]]
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

container_has_readonly_mount() {
    local container="$1" destination="$2"
    docker inspect "${container}" 2>/dev/null | jq -e --arg destination "${destination}" '
      .[0].Mounts | any(.Destination == $destination and .RW == false)
    ' >/dev/null
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
    local label="$1" path ufw_status
    STAGE_UFW_SNAPSHOT="$(mktemp -d "${PRIVATE_DIR}/.${label}-ufw.XXXXXX")"
    chmod 0700 "${STAGE_UFW_SNAPSHOT}"
    ufw_status="$(ufw status)"
    if grep -Fq 'Status: active' <<<"${ufw_status}"; then
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
                "${PRIVATE_DIR}/modules-file.before" \
                "${PRIVATE_DIR}/qdisc-before.txt"; do
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
        if [[ "${RW_ENABLE_UFW:-1}" != 1 ]]; then
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
    ufw allow proto tcp from "${PANEL_IPV4}" to any port "${NODE_PORT}" comment "Remnawave Panel ${NODE_CODE}" >/dev/null
    if ((broad == 1)); then
        warn "Replacing the broad Node API rule on ${NODE_PORT} with the verified Panel-IP allow."
        for _ in 1 2 3 4; do
            if ufw status | awk -v p="${NODE_PORT}" '
                ($1 == p || $1 == p"/tcp") && $2 == "ALLOW" &&
                ($0 ~ /Anywhere/ || $0 ~ /0\.0\.0\.0\/0/ || $0 ~ /::\/0/) {found=1}
                END {exit !found}
            '; then
                ufw --force delete allow "${NODE_PORT}/tcp" >/dev/null 2>&1 || \
                    ufw --force delete allow "${NODE_PORT}" >/dev/null
            else
                break
            fi
        done
        if ufw status | awk -v p="${NODE_PORT}" '
            ($1 == p || $1 == p"/tcp") && $2 == "ALLOW" &&
            ($0 ~ /Anywhere/ || $0 ~ /0\.0\.0\.0\/0/ || $0 ~ /::\/0/) {found=1}
            END {exit !found}
        '; then
            die "Could not automatically remove every broad Node API rule on ${NODE_PORT}."
        fi
    fi
    ufw allow 443/tcp comment "Remnawave edge ${NODE_CODE}" >/dev/null
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || \
        ufw allow 443/udp comment "Remnawave Hysteria2 ${NODE_CODE}" >/dev/null
    ufw status | awk -v p="${NODE_PORT}/tcp" -v ip="${PANEL_IPV4}" '
        $1 == p && $2 == "ALLOW" && index($0, ip) {found=1}
        END {exit !found}
    ' || die 'The exact Panel-IP UFW allow rule was not observed after insertion.'

    for backend in "${RAW_BACKEND_PORT}" "${EXTERNAL_REALITY_BACKEND_PORT}" \
        "${XHTTP_BACKEND_PORT}" "${CADDY_BACKEND_PORT}" \
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
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        [[ "${REALITY_SNI}" != "${XHTTP_SNI}" ]] || die 'Self/cover and XHTTP domains must be different.'
    fi
    validate_ipv4 "${EDGE_IPV4}" || die 'Invalid EDGE_IPV4 in state.'
    validate_ipv4 "${PANEL_IPV4}" || die 'Invalid PANEL_IPV4 in state.'
    validate_port "${NODE_PORT}" || die 'Invalid NODE_PORT in state.'
    case "${NODE_PORT}" in
        443|"${RAW_BACKEND_PORT}"|"${XHTTP_BACKEND_PORT}"|"${EXTERNAL_REALITY_BACKEND_PORT}"|\
        "${CADDY_BACKEND_PORT}"|\
        "${HYSTERIA_MASQ_PORT}"|"${HAPROXY_STATS_PORT}"|"${RAW_TEST_PORT}"|\
        "${RAW_FRAGMENT_TEST_PORT}"|"${XHTTP_TEST_PORT}"|"${HYSTERIA_TEST_PORT}"|\
        "${EXTERNAL_REALITY_TEST_PORT}")
            die 'NODE_PORT in state conflicts with an edge or verification listener.' ;;
    esac
    [[ "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
        die 'Invalid ACME_EMAIL in state.'
    [[ "${NODE_SLUG}" =~ ^[a-z0-9][a-z0-9-]{1,31}$ ]] || die 'Invalid NODE_SLUG in state.'
    [[ "${ENABLE_SELF_REALITY}" =~ ^[01]$ ]] || die 'Invalid ENABLE_SELF_REALITY in state.'
    [[ "${ENABLE_EXTERNAL_REALITY}" =~ ^[01]$ ]] || die 'Invalid ENABLE_EXTERNAL_REALITY in state.'
    [[ "${ENABLE_XHTTP}" =~ ^[01]$ ]] || die 'Invalid ENABLE_XHTTP in state.'
    [[ "${ENABLE_HYSTERIA}" =~ ^[01]$ ]] || die 'Invalid ENABLE_HYSTERIA in state.'
    ((ENABLE_SELF_REALITY + ENABLE_EXTERNAL_REALITY + ENABLE_XHTTP + ENABLE_HYSTERIA > 0)) || \
        die 'No transport is enabled in state.'
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        [[ "${REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die 'Invalid REALITY_SHORT_ID in state.'
        [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] || \
            die 'Missing self-SNI REALITY material in state.'
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        validate_external_target_format "${EXTERNAL_REALITY_TARGET}" || \
            die 'Invalid EXTERNAL_REALITY_TARGET in state.'
        validate_fqdn "${EXTERNAL_REALITY_SNI}" || die 'Invalid EXTERNAL_REALITY_SNI in state.'
        [[ "${EXTERNAL_REALITY_TARGET%:*}" == "${EXTERNAL_REALITY_SNI}" ]] || \
            die 'External REALITY target hostname and SNI must match in this wizard.'
        [[ "${EXTERNAL_REALITY_SNI}" != "${REALITY_SNI}" ]] || \
            die 'External REALITY SNI must differ from the owned cover/self-SNI domain.'
        [[ "${ENABLE_XHTTP}" != 1 || "${EXTERNAL_REALITY_SNI}" != "${XHTTP_SNI}" ]] || \
            die 'External REALITY SNI must differ from the XHTTP domain.'
        [[ "${EXTERNAL_REALITY_SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || \
            die 'Invalid external REALITY shortId in state.'
        [[ -n "${EXTERNAL_REALITY_PRIVATE_KEY}" && -n "${EXTERNAL_REALITY_PUBLIC_KEY}" ]] || \
            die 'Missing external REALITY material in state.'
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        [[ "${XHTTP_PATH}" =~ ^/api/v1/[0-9a-f]{48}/$ ]] || die 'Invalid XHTTP_PATH in state.'
    fi
    [[ "${ENABLE_RAW_FRAGMENT}" =~ ^[01]$ ]] || die 'Invalid ENABLE_RAW_FRAGMENT in state.'
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        [[ "${FRAGMENT_REALITY}" == self || "${FRAGMENT_REALITY}" == external ]] || \
            die 'FRAGMENT_REALITY must be self or external.'
        [[ "${FRAGMENT_REALITY}" != self || "${ENABLE_SELF_REALITY}" == 1 ]] || \
            die 'Fragment Host selects disabled self-SNI REALITY.'
        [[ "${FRAGMENT_REALITY}" != external || "${ENABLE_EXTERNAL_REALITY}" == 1 ]] || \
            die 'Fragment Host selects disabled external REALITY.'
    fi
    [[ "${BLOCK_CLIENT_QUIC}" =~ ^[01]$ ]] || die 'Invalid BLOCK_CLIENT_QUIC in state.'
    [[ "${APPLY_TUNING}" =~ ^[01]$ ]] || die 'Invalid APPLY_TUNING in state.'
    validate_fingerprint "${CLIENT_FINGERPRINT}" || die 'Invalid CLIENT_FINGERPRINT in state.'
}

show_configuration_summary() {
    local transports=''
    local fragment_status='disabled' quic_status='disabled' tuning_status='disabled'
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || transports='RAW/REALITY self-SNI'
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        transports+="${transports:+ + }RAW/REALITY external"
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then transports+="${transports:+ + }TLS/XHTTP"; fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then transports+="${transports:+ + }Hysteria2"; fi
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || fragment_status="enabled on ${FRAGMENT_REALITY} REALITY"
    [[ "${BLOCK_CLIENT_QUIC}" != 1 ]] || quic_status='enabled'
    [[ "${APPLY_TUNING}" != 1 ]] || tuning_status='enabled'
    ui_section 'Configuration summary' 'safe values only; generated keys and paths stay hidden'
    ui_kv 'Node name' "${NODE_SLUG}"
    ui_kv 'Install directory' "${INSTALL_DIR}"
    ui_kv 'Edge IPv4' "${EDGE_IPV4}"
    ui_kv 'Panel egress IPv4' "${PANEL_IPV4}"
    ui_kv 'Node API' "${NODE_PORT}/tcp (Panel allowlist only)"
    ui_kv 'Owned cover domain' "${REALITY_SNI}"
    [[ "${ENABLE_XHTTP}" != 1 ]] || ui_kv 'XHTTP domain' "${XHTTP_SNI}"
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
        ui_kv 'External REALITY' "${EXTERNAL_REALITY_TARGET} (measured target)"
    ui_kv 'Transports' "${transports}"
    ui_kv 'Client fingerprint' "${CLIENT_FINGERPRINT}"
    ui_kv 'Fragment A/B Host' "${fragment_status}"
    ui_kv 'Inner QUIC block' "${quic_status}"
    ui_kv 'Reversible tuning' "${tuning_status}"
}

init_stage() {
    local detected_ip default_node_name
    announce_stage init
    require_root
    set_paths
    need_commands
    persist_installer
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
        validate_loaded_state
        pull_images
        if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
            probe_external_reality_target "${EXTERNAL_REALITY_TARGET}" "${EXTERNAL_REALITY_SNI}" || \
                die 'Saved external REALITY target no longer passes DNS/TLS/Xray validation.'
        fi
        render_validate_transaction
        # Re-serialize older protected state so legacy self-signed HY2 pin
        # fields disappear after a successful artifact migration.
        write_state
        log "Existing protected state and every generated artifact were rebuilt and validated."
        return 0
    fi

    detected_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1)"
    REALITY_SNI="${RW_REALITY_SNI:-}"
    XHTTP_SNI="${RW_XHTTP_SNI:-}"
    EDGE_IPV4="${RW_EDGE_IPV4:-}"
    PANEL_IPV4="${RW_PANEL_IPV4:-78.17.85.117}"
    ACME_EMAIL="${RW_ACME_EMAIL:-thisaintu@proton.me}"
    NODE_PORT="${RW_NODE_PORT:-}"
    NODE_SLUG="${RW_NODE_NAME:-}"
    ENABLE_SELF_REALITY="${RW_ENABLE_SELF_REALITY:-}"
    ENABLE_EXTERNAL_REALITY="${RW_ENABLE_EXTERNAL_REALITY:-}"
    ENABLE_XHTTP="${RW_ENABLE_XHTTP:-}"
    ENABLE_HYSTERIA="${RW_ENABLE_HYSTERIA:-}"
    ENABLE_RAW_FRAGMENT="${RW_ENABLE_RAW_FRAGMENT:-0}"
    FRAGMENT_REALITY="${RW_FRAGMENT_REALITY:-self}"
    BLOCK_CLIENT_QUIC="${RW_BLOCK_CLIENT_QUIC:-1}"
    APPLY_TUNING="${RW_APPLY_TUNING:-1}"
    CLIENT_FINGERPRINT="${RW_CLIENT_FINGERPRINT:-firefox}"
    ui_section 'Transport selection' 'each enabled transport gets its own inbound and physical Host'
    prompt_yes_no ENABLE_SELF_REALITY 'Enable RAW/TCP + REALITY self-SNI?' 1
    prompt_yes_no ENABLE_EXTERNAL_REALITY 'Enable RAW/TCP + REALITY on a measured external domain?' 1
    prompt_yes_no ENABLE_XHTTP 'Enable VLESS XHTTP auto behind ordinary TLS/HTTP2?' 1
    prompt_yes_no ENABLE_HYSTERIA 'Enable Hysteria2 on UDP/443?' 1
    [[ "${ENABLE_SELF_REALITY}" =~ ^[01]$ && "${ENABLE_EXTERNAL_REALITY}" =~ ^[01]$ && \
       "${ENABLE_XHTTP}" =~ ^[01]$ && "${ENABLE_HYSTERIA}" =~ ^[01]$ ]] || \
        die 'Transport selections must be 0 or 1.'
    ((ENABLE_SELF_REALITY + ENABLE_EXTERNAL_REALITY + ENABLE_XHTTP + ENABLE_HYSTERIA > 0)) || \
        die 'Select at least one transport.'
    if [[ "${ENABLE_SELF_REALITY}" != 1 && "${ENABLE_EXTERNAL_REALITY}" != 1 ]]; then
        ENABLE_RAW_FRAGMENT=0
    fi
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        if [[ "${ENABLE_SELF_REALITY}" == 1 && "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
            prompt_value FRAGMENT_REALITY 'Fragment Host base (self/external)' 'external'
        elif [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
            FRAGMENT_REALITY='external'
        else
            FRAGMENT_REALITY='self'
        fi
    else
        FRAGMENT_REALITY='self'
    fi
    prompt_value REALITY_SNI 'Owned cover/self-SNI domain'
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        prompt_value XHTTP_SNI 'Second owned domain for TLS/XHTTP'
    else
        XHTTP_SNI="${REALITY_SNI}"
    fi
    prompt_value EDGE_IPV4 'Public IPv4 of this Node' "${detected_ip}"
    prompt_value NODE_PORT 'Node API port (Panel control plane only)' '3334'
    default_node_name="${REALITY_SNI%%.*}"
    default_node_name="$(printf '%s' "${default_node_name}" | tr '[:upper:]_' '[:lower:]-' | \
        tr -cd 'a-z0-9-' | cut -c1-24)"
    default_node_name="${default_node_name:-edge-node}"
    NODE_SLUG="${NODE_SLUG:-${default_node_name}}"
    REALITY_SNI="${REALITY_SNI,,}"
    XHTTP_SNI="${XHTTP_SNI,,}"
    CLIENT_FINGERPRINT="${CLIENT_FINGERPRINT,,}"
    validate_fqdn "${REALITY_SNI}" || die "Invalid domain: ${REALITY_SNI}"
    validate_fqdn "${XHTTP_SNI}" || die "Invalid domain: ${XHTTP_SNI}"
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        [[ "${REALITY_SNI}" != "${XHTTP_SNI}" ]] || die 'Use two distinct owned domain names when XHTTP is enabled.'
    fi
    validate_ipv4 "${EDGE_IPV4}" || die "Invalid edge IPv4: ${EDGE_IPV4}"
    validate_ipv4 "${PANEL_IPV4}" || die "Invalid Panel IPv4: ${PANEL_IPV4}"
    validate_port "${NODE_PORT}" || die "Invalid Node port: ${NODE_PORT}"
    [[ "${NODE_SLUG}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,31}$ ]] || \
        die 'Node name must be 2-32 ASCII letters, digits or hyphens.'
    [[ "${ENABLE_SELF_REALITY}" =~ ^[01]$ ]] || die 'RW_ENABLE_SELF_REALITY must be 0 or 1.'
    [[ "${ENABLE_EXTERNAL_REALITY}" =~ ^[01]$ ]] || die 'RW_ENABLE_EXTERNAL_REALITY must be 0 or 1.'
    [[ "${ENABLE_XHTTP}" =~ ^[01]$ ]] || die 'RW_ENABLE_XHTTP must be 0 or 1.'
    [[ "${ENABLE_HYSTERIA}" =~ ^[01]$ ]] || die 'RW_ENABLE_HYSTERIA must be 0 or 1.'
    [[ "${ENABLE_RAW_FRAGMENT}" =~ ^[01]$ ]] || die 'RW_ENABLE_RAW_FRAGMENT must be 0 or 1.'
    [[ "${BLOCK_CLIENT_QUIC}" =~ ^[01]$ ]] || die 'RW_BLOCK_CLIENT_QUIC must be 0 or 1.'
    [[ "${APPLY_TUNING}" =~ ^[01]$ ]] || die 'RW_APPLY_TUNING must be 0 or 1.'
    validate_fingerprint "${CLIENT_FINGERPRINT}" || die 'Invalid RW_CLIENT_FINGERPRINT characters.'
    [[ "${ACME_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die 'Invalid ACME email.'
    case "${NODE_PORT}" in
        443|"${RAW_BACKEND_PORT}"|"${XHTTP_BACKEND_PORT}"|"${EXTERNAL_REALITY_BACKEND_PORT}"|\
        "${CADDY_BACKEND_PORT}"|\
        "${HYSTERIA_MASQ_PORT}"|"${HAPROXY_STATS_PORT}"|"${RAW_TEST_PORT}"|\
        "${RAW_FRAGMENT_TEST_PORT}"|"${XHTTP_TEST_PORT}"|"${HYSTERIA_TEST_PORT}"|\
        "${EXTERNAL_REALITY_TEST_PORT}")
            die "Node port ${NODE_PORT} conflicts with the edge." ;;
    esac

    NODE_SLUG="${NODE_SLUG,,}"
    NODE_CODE="$(printf '%s' "${NODE_SLUG}" | tr '[:lower:]-' '[:upper:]_')"
    NODE_CODE_LOWER="${NODE_SLUG}"
    PROFILE_NAME="RW-EDGE-${NODE_CODE}"
    RAW_TAG="RW_${NODE_CODE}_RAW_REALITY_SELF"
    XHTTP_TAG="RW_${NODE_CODE}_XHTTP_TLS"
    EXTERNAL_REALITY_TAG="RW_${NODE_CODE}_RAW_REALITY_EXTERNAL"
    HYSTERIA_TAG="RW_${NODE_CODE}_HYSTERIA2"
    NODE_CONTAINER="rw-edge-node-${NODE_CODE_LOWER}"
    HAPROXY_CONTAINER="rw-edge-haproxy-${NODE_CODE_LOWER}"
    CADDY_CONTAINER="rw-edge-caddy-${NODE_CODE_LOWER}"
    COMPOSE_PROJECT="rw-edge-${NODE_CODE_LOWER}"

    install -d -m 0700 "${PRIVATE_DIR}"
    pull_images
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        select_external_reality_target
        [[ "${EXTERNAL_REALITY_SNI}" != "${REALITY_SNI}" ]] || \
            die 'External REALITY SNI must differ from the owned cover/self-SNI domain.'
        [[ "${ENABLE_XHTTP}" != 1 || "${EXTERNAL_REALITY_SNI}" != "${XHTTP_SNI}" ]] || \
            die 'External REALITY SNI must differ from the XHTTP domain.'
    fi
    show_configuration_summary
    generate_material
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
    if [[ -z "${secret}" && -f "${PRIVATE_DIR}/node.env" && ! -L "${PRIVATE_DIR}/node.env" ]] && \
       [[ "$(stat -c '%a:%u' "${PRIVATE_DIR}/node.env")" == '600:0' ]] && \
       awk '
         BEGIN {count=0; valid=0}
         /^SECRET_KEY=/ {
           count++
           value=substr($0, 12)
           if (length(value) >= 32 && value != "__PANEL_SECRET_REQUIRED__" && value !~ /[[:space:]]/) valid=1
         }
         END {exit !(count == 1 && valid == 1)}
       ' "${PRIVATE_DIR}/node.env"; then
        log 'Reusing the protected Node SECRET_KEY already saved by the previous attempt.'
        return 0
    fi
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

panel_control_observed() {
    local started_at
    panel_session_present && return 0
    container_is_running "${NODE_CONTAINER}" || return 1
    started_at="$(docker inspect -f '{{.State.StartedAt}}' "${NODE_CONTAINER}" 2>/dev/null || true)"
    [[ -n "${started_at}" ]] || return 1
    docker logs --since "${started_at}" "${NODE_CONTAINER}" 2>&1 | tr -d '\000' | \
        awk -v ip="${PANEL_IPV4}" '
          index($0, "Attempt to start XTLS took:") &&
          (index($0, "(IP: " ip ")") || index($0, "(IP: ::ffff:" ip ")")) {found=1}
          END {exit !found}
        '
}

wait_for_node_ready() {
    local attempt ready
    for attempt in $(seq 1 90); do
        ready=1
        port_is_listening "${NODE_PORT}" || ready=0
        [[ "${ENABLE_SELF_REALITY}" != 1 ]] || port_is_listening "${RAW_BACKEND_PORT}" || ready=0
        [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
            port_is_listening "${EXTERNAL_REALITY_BACKEND_PORT}" || ready=0
        [[ "${ENABLE_XHTTP}" != 1 ]] || port_is_listening "${XHTTP_BACKEND_PORT}" || ready=0
        [[ "${ENABLE_HYSTERIA}" != 1 ]] || udp_port_is_listening 443 || ready=0
        panel_control_observed || ready=0
        if [[ "${ready}" == 1 ]]; then
            log 'Node API, all selected Xray transports and a successful Panel management exchange are ready.'
            return 0
        fi
        sleep 2
    done
    docker logs --tail 40 "${NODE_CONTAINER}" 2>&1 | sed -E 's/(SECRET_KEY=)[^ ]+/\1[REDACTED]/g' >&2 || true
    die "Node did not become Panel-managed within 180 seconds. Resume with: sudo ${INSTALL_DIR}/remnawave-edge-oneclick.sh node"
}

ensure_caddy_certificates() {
    [[ "${ENABLE_HYSTERIA}" == 1 ]] || return 0
    check_dns
    assert_port_free_or_owned 443 "${HAPROXY_CONTAINER}"
    assert_port_free_or_owned "${CADDY_BACKEND_PORT}" "${CADDY_CONTAINER}"
    assert_port_free_or_owned "${HYSTERIA_MASQ_PORT}" "${CADDY_CONTAINER}"
    assert_port_free_or_owned "${HAPROXY_STATS_PORT}" "${HAPROXY_CONTAINER}"

    if ! container_is_running "${HAPROXY_CONTAINER}"; then
        STAGE_STOP_HAPROXY=1
        log 'Starting HAProxy so Caddy can complete public TLS-ALPN validation...'
        docker compose --env-file "${PRIVATE_DIR}/edge.env" \
            -f "${INSTALL_DIR}/docker-compose.edge.yml" up -d haproxy
    fi
    wait_for_owned_tcp_listener 443 "${HAPROXY_CONTAINER}" || \
        die 'HAProxy did not bind public TCP/443 within 10 seconds.'

    if ! container_is_running "${CADDY_CONTAINER}"; then
        STAGE_STOP_CADDY=1
        log 'Starting Caddy to issue publicly trusted certificates before Node/Xray...'
        docker compose --env-file "${PRIVATE_DIR}/edge.env" \
            -f "${INSTALL_DIR}/docker-compose.edge.yml" up -d caddy
    else
        log 'Reloading the validated Caddyfile before checking ACME material...'
        docker exec "${CADDY_CONTAINER}" caddy reload \
            --config /etc/caddy/Caddyfile --adapter caddyfile \
            --address unix//run/caddy-admin.sock --force >/dev/null
    fi
    wait_for_caddy_tls "${REALITY_SNI}" || {
        docker logs --tail 80 "${CADDY_CONTAINER}" >&2 || true
        die "Caddy did not obtain trusted HTTPS for ${REALITY_SNI}."
    }
    if [[ "${XHTTP_SNI}" != "${REALITY_SNI}" ]]; then
        wait_for_caddy_tls "${XHTTP_SNI}" || {
            docker logs --tail 80 "${CADDY_CONTAINER}" >&2 || true
            die "Caddy did not obtain trusted HTTPS for ${XHTTP_SNI}."
        }
    fi
    validate_hysteria_material
    success "Caddy certificate for Hysteria2 (${XHTTP_SNI}) is public, current and key-matched."
}

check_negative_mtls() {
    local attempt code curl_probe tls_probe
    curl_probe="$(curl --silent --show-error --connect-timeout 5 --max-time 8 \
        --insecure --output /dev/null --write-out '%{http_code}' \
        "https://127.0.0.1:${NODE_PORT}/" 2>&1 || true)"
    code="$(grep -Eo '[0-9]{3}$' <<<"${curl_probe}" || true)"
    [[ "${code}" == 000 || -z "${code}" ]] || \
        die "Node API unexpectedly answered unauthenticated HTTPS with HTTP ${code}."
    if grep -Eqi 'certificate required|alert number 116' <<<"${curl_probe}"; then return 0; fi
    for attempt in 1 2 3 4 5; do
        tls_probe="$(timeout 8 openssl s_client -connect "127.0.0.1:${NODE_PORT}" \
            -tls1_3 -brief </dev/null 2>&1 || true)"
        if grep -Eqi 'certificate required|alert number 116' <<<"${tls_probe}"; then return 0; fi
        sleep 0.5
    done
    die 'Node API did not prove mandatory client-certificate rejection over TLS 1.3.'
}

apply_tuning_loaded() {
    local key snapshot="${PRIVATE_DIR}/sysctl-before.txt" snapshot_tmp default_interface live_qdisc
    local qdisc_snapshot="${PRIVATE_DIR}/qdisc-before.txt"
    local sysctl_target='/etc/sysctl.d/99-remnawave-edge.conf'
    local module_target='/etc/modules-load.d/remnawave-edge.conf'
    local keys=(
      net.core.default_qdisc net.ipv4.tcp_congestion_control
      net.ipv4.tcp_mtu_probing net.core.somaxconn
      net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog
      net.core.rmem_max net.core.wmem_max
      net.ipv4.tcp_rmem net.ipv4.tcp_wmem
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
    else
        # Upgrade an older snapshot before adding new tuning keys. Existing
        # values remain untouched and newly managed keys keep their exact
        # pre-upgrade values for a future untune/rollback-host operation.
        snapshot_tmp="$(mktemp "${PRIVATE_DIR}/.sysctl-before.XXXXXX")"
        cp -- "${snapshot}" "${snapshot_tmp}"
        for key in "${keys[@]}"; do
            if ! awk -F= -v wanted="${key}" '$1 == wanted {found=1} END {exit !found}' \
                "${snapshot}"; then
                printf '%s=%s\n' "${key}" "$(sysctl -n "${key}")" >>"${snapshot_tmp}"
            fi
        done
        chmod 0600 "${snapshot_tmp}"
        mv -f -- "${snapshot_tmp}" "${snapshot}"
    fi
    default_interface="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
    [[ "${default_interface}" =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'Could not determine a safe default network interface.'
    live_qdisc="$(tc qdisc show dev "${default_interface}" 2>/dev/null | awk 'NR == 1 {print $2}')"
    [[ -n "${live_qdisc}" ]] || die "Could not read the live qdisc on ${default_interface}."
    if [[ ! -f "${qdisc_snapshot}" ]]; then
        printf '%s\t%s\n' "${default_interface}" "${live_qdisc}" >"${qdisc_snapshot}"
        chmod 0600 "${qdisc_snapshot}"
    fi
    modprobe tcp_bbr
    install -m 0644 "${INSTALL_DIR}/99-remnawave-edge.conf" "${sysctl_target}"
    printf 'tcp_bbr\n' >"${module_target}"
    chmod 0644 "${module_target}"
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || die 'BBR did not become active.'
    tc qdisc replace dev "${default_interface}" root fq
    live_qdisc="$(tc qdisc show dev "${default_interface}" 2>/dev/null | awk 'NR == 1 {print $2}')"
    [[ "${live_qdisc}" == fq ]] || die "Could not activate fq on ${default_interface}."
    [[ "$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')" == 33554432 ]] || \
        die 'TCP receive autotuning ceiling did not become 32 MiB.'
    [[ "$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')" == 33554432 ]] || \
        die 'TCP send autotuning ceiling did not become 32 MiB.'
    log "Applied reversible BBR, live fq on ${default_interface}, MTU probing, 32 MiB TCP autotuning, backlog and UDP buffers."
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
    local line key value snapshot sysctl_target module_target qdisc_interface qdisc_kind
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
    if [[ -f "${PRIVATE_DIR}/qdisc-before.txt" ]]; then
        IFS=$'\t' read -r qdisc_interface qdisc_kind <"${PRIVATE_DIR}/qdisc-before.txt"
        [[ "${qdisc_interface}" =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'Recorded qdisc interface is unsafe.'
        case "${qdisc_kind}" in
            fq|fq_codel|cake|pfifo_fast)
                tc qdisc replace dev "${qdisc_interface}" root "${qdisc_kind}"
                ;;
            *)
                warn "Recorded qdisc ${qdisc_kind:-unknown} cannot be safely reconstructed automatically."
                ;;
        esac
    fi
    log 'Restored the recorded sysctl and supported live-qdisc values from before tuning.'
}

untune_stage() {
    announce_stage untune
    require_root
    load_state
    restore_tuning_loaded
}

node_stage() {
    local node_was_running=0 node_reconciled=0 node_id_before node_id_after
    announce_stage node
    require_root
    need_commands
    load_state
    validate_loaded_state
    pull_images
    render_validate_transaction
    assert_port_free_or_owned "${NODE_PORT}" "${NODE_CONTAINER}"
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || \
        assert_port_free_or_owned "${RAW_BACKEND_PORT}" "${NODE_CONTAINER}"
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
        assert_port_free_or_owned "${EXTERNAL_REALITY_BACKEND_PORT}" "${NODE_CONTAINER}"
    [[ "${ENABLE_XHTTP}" != 1 ]] || \
        assert_port_free_or_owned "${XHTTP_BACKEND_PORT}" "${NODE_CONTAINER}"
    if [[ "${ENABLE_HYSTERIA}" == 1 ]] && udp_port_is_listening 443 && \
       ! container_is_running "${NODE_CONTAINER}"; then
        die 'UDP/443 is occupied by another service.'
    fi
    container_is_running "${NODE_CONTAINER}" && node_was_running=1
    arm_stage_rollback node
    apply_firewall
    if [[ "${APPLY_TUNING}" == 1 && "${node_was_running}" != 1 ]]; then
        apply_tuning_loaded
    fi
    ensure_caddy_certificates
    # The initial init validation deliberately omits HY2 until ACME material
    # exists. This second transaction validates the complete profile against
    # the pinned Xray with Caddy's real read-only certificate volume mounted.
    render_validate_transaction
    if [[ "${node_was_running}" == 1 ]]; then
        node_id_before="$(docker inspect -f '{{.Id}}' "${NODE_CONTAINER}")"
        docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" up -d node
        node_id_after="$(docker inspect -f '{{.Id}}' "${NODE_CONTAINER}")"
        if [[ "${node_id_before}" != "${node_id_after}" ]]; then
            log 'Node Compose drift was reconciled; waiting for Panel and Xray readiness...'
            wait_for_node_ready
            node_reconciled=1
        fi
        if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
            container_has_readonly_mount "${NODE_CONTAINER}" "${CADDY_DATA_CONTAINER_DIR}" || \
                die 'Node container is missing the required read-only Caddy certificate volume.'
        fi
        port_is_listening "${NODE_PORT}" || die 'Existing managed Node has no API listener.'
        [[ "${ENABLE_SELF_REALITY}" != 1 ]] || port_is_listening "${RAW_BACKEND_PORT}" || \
            die 'Existing managed Node has no self-SNI REALITY listener.'
        [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
            port_is_listening "${EXTERNAL_REALITY_BACKEND_PORT}" || \
            die 'Existing managed Node has no external REALITY listener.'
        [[ "${ENABLE_XHTTP}" != 1 ]] || port_is_listening "${XHTTP_BACKEND_PORT}" || \
            die 'Existing managed Node has no XHTTP listener.'
        panel_control_observed || die 'Existing managed Node has no successful Panel management exchange.'
        check_negative_mtls
        [[ "${ENABLE_XHTTP}" != 1 ]] || check_runtime_path
        if [[ "${node_reconciled}" == 1 ]]; then
            log 'Existing managed Node was reconciled and passed control-plane/runtime checks.'
        else
            log 'Existing managed Node passed control-plane and runtime-contract checks; it was not recreated.'
        fi
        commit_stage
        return 0
    fi
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
    announce_stage template
    require_root
    load_state
    validate_loaded_state
    render_happ_rules
    render_auto_template
    render_panel_stage_two
    [[ -s "${PRIVATE_DIR}/xray-json-auto.ready.json" ]] || die 'AUTO template was not rendered.'
    jq empty "${PRIVATE_DIR}/xray-json-auto.ready.json"
    validate_auto_template_model "${PRIVATE_DIR}/xray-json-auto.ready.json"
    success 'XRAY_JSON AUTO template rendered and validated without UUID input.'
    ui_file 'Ready template' "${PRIVATE_DIR}/xray-json-auto.ready.json"
    ui_file 'Exact Panel steps' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"
    if [[ "${SHOW_VALUES}" == 1 ]]; then sed -n '1,240p' "${PRIVATE_DIR}/PANEL-STAGE-2.txt"; fi
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

wait_for_caddy_tls() {
    local domain="$1" attempt
    for attempt in $(seq 1 90); do
        if curl --silent --show-error --fail --noproxy '*' --max-time 10 \
            --resolve "${domain}:${CADDY_BACKEND_PORT}:127.0.0.1" \
            "https://${domain}:${CADDY_BACKEND_PORT}/health.txt" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_owned_tcp_listener() {
    local port="$1" container="$2" attempt
    for attempt in $(seq 1 40); do
        if port_is_listening "${port}" && tcp_port_owned_by_container "${port}" "${container}"; then
            return 0
        fi
        sleep 0.25
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
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || port_is_listening "${RAW_BACKEND_PORT}" || \
        die 'Self-SNI REALITY backend is not listening.'
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
        port_is_listening "${EXTERNAL_REALITY_BACKEND_PORT}" || \
        die 'External REALITY backend is not listening.'
    [[ "${ENABLE_XHTTP}" != 1 ]] || port_is_listening "${XHTTP_BACKEND_PORT}" || \
        die 'XHTTP backend is not listening.'
    panel_control_observed || die 'No successful Panel management exchange with the Node API.'
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
    wait_for_owned_tcp_listener 443 "${HAPROXY_CONTAINER}" || \
        die 'HAProxy did not bind public TCP/443 within 10 seconds.'
    log 'Starting Caddy and obtaining trusted certificates...'
    [[ "${caddy_was_running}" == 1 ]] || STAGE_STOP_CADDY=1
    docker compose --env-file "${PRIVATE_DIR}/edge.env" \
        -f "${INSTALL_DIR}/docker-compose.edge.yml" up -d caddy

    wait_for_public_tls "${REALITY_SNI}" || {
        docker logs --tail 80 "${CADDY_CONTAINER}" >&2 || true
        die "Trusted HTTPS did not become ready for ${REALITY_SNI}."
    }
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        wait_for_public_tls "${XHTTP_SNI}" || {
            docker logs --tail 80 "${CADDY_CONTAINER}" >&2 || true
            die "Trusted HTTPS did not become ready for ${XHTTP_SNI}."
        }
    fi
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
       unique) == [{path: $path, mode: "auto"}]
    ' "${dump}" >/dev/null || \
        die 'Live Node XHTTP path or auto mode differs from protected edge state.'
)

verify_stage() {
    local exact_code decoy_code loopback_port
    local -a loopback_ports=("${CADDY_BACKEND_PORT}" "${HYSTERIA_MASQ_PORT}" "${HAPROXY_STATS_PORT}")
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
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        port_is_listening "${RAW_BACKEND_PORT}" || die 'Self-SNI REALITY backend is not listening.'
        loopback_ports+=("${RAW_BACKEND_PORT}")
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        port_is_listening "${EXTERNAL_REALITY_BACKEND_PORT}" || \
            die 'External-target REALITY backend is not listening.'
        loopback_ports+=("${EXTERNAL_REALITY_BACKEND_PORT}")
        probe_external_reality_target "${EXTERNAL_REALITY_TARGET}" "${EXTERNAL_REALITY_SNI}" || \
            die 'The configured external REALITY target no longer passes DNS/TLS/Xray validation.'
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        port_is_listening "${XHTTP_BACKEND_PORT}" || die 'XHTTP backend is not listening.'
        loopback_ports+=("${XHTTP_BACKEND_PORT}")
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        udp_port_is_listening 443 || die 'Hysteria2 UDP/443 is not listening.'
        udp_port_owned_by_container 443 "${NODE_CONTAINER}" || \
            die 'UDP/443 is not owned by the managed Node container.'
        container_has_readonly_mount "${NODE_CONTAINER}" "${CADDY_DATA_CONTAINER_DIR}" || \
            die 'Node does not have Caddy certificate storage mounted read-only.'
        validate_hysteria_material
    else
        ! udp_port_is_listening 443 || die 'UDP/443 unexpectedly listens.'
    fi
    port_is_listening "${CADDY_BACKEND_PORT}" || die 'Caddy loopback backend is not listening.'
    port_is_listening "${HYSTERIA_MASQ_PORT}" || die 'Caddy Hysteria masquerade origin is not listening.'
    port_is_listening "${HAPROXY_STATS_PORT}" || die 'HAProxy loopback stats is not listening.'
    for loopback_port in "${loopback_ports[@]}"; do
        port_is_loopback_only "${loopback_port}" || die "Backend ${loopback_port} is not loopback-only."
    done
    [[ -z "$(ss -H -ltn 'sport = :80')" ]] || die 'TCP/80 unexpectedly listens; this design uses TLS-ALPN on TCP/443 only.'
    panel_control_observed || die 'No successful Panel management exchange with the Node API.'
    check_negative_mtls
    check_https_cover "${REALITY_SNI}"
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
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
    fi
    log 'PASS: DNS, mTLS control plane, all selected listeners, cover HTTPS and transport routing.'
}

render_reality_auth_client() {
    local runtime="$1" tag="$2" server_name="$3" public_key="$4" socks_port="$5" output="$6"
    local user_id short_id
    user_id="$(jq -r --arg tag "${tag}" \
        '.inbounds[] | select(.tag == $tag) | .settings.clients[0].id // empty' "${runtime}")"
    short_id="$(jq -r --arg tag "${tag}" \
        '.inbounds[] | select(.tag == $tag) | .streamSettings.realitySettings.shortIds[0] // empty' "${runtime}")"
    validate_uuid "${user_id}" || die "No active user credential was injected into ${tag}."
    [[ "${short_id}" =~ ^[0-9a-fA-F]{16}$ ]] || die "Live REALITY shortId is invalid for ${tag}."
    jq -n --arg address "${EDGE_IPV4}" --arg id "${user_id}" \
        --arg server_name "${server_name}" --arg public_key "${public_key}" \
        --arg short_id "${short_id}" --arg fingerprint "${CLIENT_FINGERPRINT}" \
        --argjson socks_port "${socks_port}" '
      {
        log: {loglevel: "warning"},
        inbounds: [{
          tag: "socks-in", listen: "127.0.0.1", port: $socks_port,
          protocol: "socks", settings: {auth: "noauth", udp: true}
        }],
        outbounds: [{
          tag: "proxy", protocol: "vless",
          settings: {vnext: [{
            address: $address, port: 443,
            users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]
          }]},
          streamSettings: {
            network: "raw", security: "reality",
            realitySettings: {
              serverName: $server_name, fingerprint: $fingerprint,
              publicKey: $public_key, shortId: $short_id, spiderX: "/"
            }
          }
        }]
      }
    ' >"${output}"
    chmod 0600 "${output}"
}

render_auth_clients() {
    local runtime="$1" self_config="$2" external_config="$3" xhttp_config="$4" hysteria_config="$5"
    local xhttp_id hysteria_auth
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        render_reality_auth_client "${runtime}" "${RAW_TAG}" "${REALITY_SNI}" \
            "${REALITY_PUBLIC_KEY}" "${RAW_TEST_PORT}" "${self_config}"
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        render_reality_auth_client "${runtime}" "${EXTERNAL_REALITY_TAG}" "${EXTERNAL_REALITY_SNI}" \
            "${EXTERNAL_REALITY_PUBLIC_KEY}" "${EXTERNAL_REALITY_TEST_PORT}" "${external_config}"
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        xhttp_id="$(jq -r --arg tag "${XHTTP_TAG}" \
            '.inbounds[] | select(.tag == $tag) | .settings.clients[0].id // empty' "${runtime}")"
        validate_uuid "${xhttp_id}" || die 'No active user credential was injected into XHTTP inbound.'
        jq -n --arg address "${EDGE_IPV4}" --arg id "${xhttp_id}" \
            --arg server_name "${XHTTP_SNI}" --arg path "${XHTTP_PATH}" \
            --arg fingerprint "${CLIENT_FINGERPRINT}" \
            --argjson socks_port "${XHTTP_TEST_PORT}" '
          {
            log: {loglevel: "warning"},
            inbounds: [{
              tag: "socks-in", listen: "127.0.0.1", port: $socks_port,
              protocol: "socks", settings: {auth: "noauth", udp: true}
            }],
            outbounds: [{
              tag: "proxy", protocol: "vless",
              settings: {vnext: [{address: $address, port: 443,
                users: [{id: $id, encryption: "none"}]}]},
              streamSettings: {
                network: "xhttp", security: "tls",
                tlsSettings: {serverName: $server_name, fingerprint: $fingerprint, alpn: ["h2"]},
                xhttpSettings: {host: $server_name, path: $path, mode: "auto"}
              }
            }]
          }
        ' >"${xhttp_config}"
        chmod 0600 "${xhttp_config}"
    fi
    if [[ "${ENABLE_HYSTERIA}" == 1 ]]; then
        hysteria_auth="$(jq -r --arg tag "${HYSTERIA_TAG}" \
            '.inbounds[] | select(.tag == $tag) | .settings.clients[0].auth // empty' "${runtime}")"
        validate_uuid "${hysteria_auth}" || die 'No active user credential was injected into Hysteria2 inbound.'
        jq -n --arg address "${EDGE_IPV4}" --arg auth "${hysteria_auth}" \
            --arg server_name "${XHTTP_SNI}" \
            --arg fingerprint "${CLIENT_FINGERPRINT}" \
            --argjson socks_port "${HYSTERIA_TEST_PORT}" '
          {
            log: {loglevel: "warning"},
            inbounds: [{
              tag: "socks-in", listen: "127.0.0.1", port: $socks_port,
              protocol: "socks", settings: {auth: "noauth", udp: true}
            }],
            outbounds: [{
              tag: "proxy", protocol: "hysteria",
              settings: {address: $address, port: 443, version: 2},
              streamSettings: {
                network: "hysteria", security: "tls",
                tlsSettings: {
                  serverName: $server_name, fingerprint: $fingerprint, alpn: ["h3"]
                },
                hysteriaSettings: {version: 2, auth: $auth}
              }
            }]
          }
        ' >"${hysteria_config}"
        chmod 0600 "${hysteria_config}"
    fi
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
    local temp_dir runtime raw_config external_config raw_fragment_config xhttp_config hysteria_config
    local fragment_base_config fragment_label
    local raw_test_container external_test_container raw_fragment_test_container
    local xhttp_test_container hysteria_test_container port
    local -a selected_test_ports=()
    require_root
    need_commands
    load_state
    validate_loaded_state
    check_container_health "${NODE_CONTAINER}" "${NODE_IMAGE}"
    check_container_health "${HAPROXY_CONTAINER}" "${HAPROXY_IMAGE}"
    check_container_health "${CADDY_CONTAINER}" "${CADDY_IMAGE}"
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || selected_test_ports+=("${RAW_TEST_PORT}")
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || selected_test_ports+=("${EXTERNAL_REALITY_TEST_PORT}")
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || selected_test_ports+=("${RAW_FRAGMENT_TEST_PORT}")
    [[ "${ENABLE_XHTTP}" != 1 ]] || selected_test_ports+=("${XHTTP_TEST_PORT}")
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || selected_test_ports+=("${HYSTERIA_TEST_PORT}")
    for port in "${selected_test_ports[@]}"; do
        port_is_listening "${port}" && die "Temporary test port ${port} is occupied."
    done
    raw_test_container="rw-edge-test-raw-${NODE_CODE_LOWER}"
    external_test_container="rw-edge-test-ext-${NODE_CODE_LOWER}"
    raw_fragment_test_container="rw-edge-test-raw-fragment-${NODE_CODE_LOWER}"
    xhttp_test_container="rw-edge-test-xhttp-${NODE_CODE_LOWER}"
    hysteria_test_container="rw-edge-test-hy2-${NODE_CODE_LOWER}"
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || ! docker inspect "${raw_test_container}" >/dev/null 2>&1 || \
        die "Stale test container exists: ${raw_test_container}"
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
        ! docker inspect "${external_test_container}" >/dev/null 2>&1 || \
        die "Stale test container exists: ${external_test_container}"
    [[ "${ENABLE_RAW_FRAGMENT}" != 1 ]] || \
        ! docker inspect "${raw_fragment_test_container}" >/dev/null 2>&1 || \
        die "Stale test container exists: ${raw_fragment_test_container}"
    [[ "${ENABLE_XHTTP}" != 1 ]] || ! docker inspect "${xhttp_test_container}" >/dev/null 2>&1 || \
        die "Stale test container exists: ${xhttp_test_container}"
    [[ "${ENABLE_HYSTERIA}" != 1 ]] || \
        ! docker inspect "${hysteria_test_container}" >/dev/null 2>&1 || \
        die "Stale test container exists: ${hysteria_test_container}"

    temp_dir="$(mktemp -d)"
    runtime="${temp_dir}/runtime.json"
    raw_config="${temp_dir}/raw-client.json"
    external_config="${temp_dir}/external-client.json"
    raw_fragment_config="${temp_dir}/raw-fragment-client.json"
    xhttp_config="${temp_dir}/xhttp-client.json"
    hysteria_config="${temp_dir}/hysteria-client.json"
    auth_cleanup() {
        docker stop --time 2 "${raw_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${external_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${raw_fragment_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${xhttp_test_container}" >/dev/null 2>&1 || true
        docker stop --time 2 "${hysteria_test_container}" >/dev/null 2>&1 || true
        if [[ -f "${runtime}" ]]; then truncate -s 0 "${runtime}"; fi
        if [[ -f "${raw_config}" ]]; then truncate -s 0 "${raw_config}"; fi
        if [[ -f "${external_config}" ]]; then truncate -s 0 "${external_config}"; fi
        if [[ -f "${raw_fragment_config}" ]]; then truncate -s 0 "${raw_fragment_config}"; fi
        if [[ -f "${xhttp_config}" ]]; then truncate -s 0 "${xhttp_config}"; fi
        if [[ -f "${hysteria_config}" ]]; then truncate -s 0 "${hysteria_config}"; fi
        find "${temp_dir}" -depth -delete 2>/dev/null || true
    }
    trap auth_cleanup EXIT RETURN
    install -m 0600 /dev/null "${runtime}"
    docker exec "${NODE_CONTAINER}" cli --dump-config-raw >"${runtime}" 2>/dev/null || \
        die 'Could not read protected live Node config.'
    render_auth_clients "${runtime}" "${raw_config}" "${external_config}" \
        "${xhttp_config}" "${hysteria_config}"
    if [[ "${ENABLE_SELF_REALITY}" == 1 ]]; then
        validate_client_config "${raw_config}"
        run_transport_test 'RAW REALITY self-SNI' "${raw_test_container}" \
            "${RAW_TEST_PORT}" "${raw_config}"
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        validate_client_config "${external_config}"
        run_transport_test "RAW REALITY ${EXTERNAL_REALITY_SNI}" "${external_test_container}" \
            "${EXTERNAL_REALITY_TEST_PORT}" "${external_config}"
    fi
    if [[ "${ENABLE_RAW_FRAGMENT}" == 1 ]]; then
        if [[ "${FRAGMENT_REALITY}" == external ]]; then
            fragment_base_config="${external_config}"
            fragment_label="RAW REALITY ${EXTERNAL_REALITY_SNI} + client fragment"
        else
            fragment_base_config="${raw_config}"
            fragment_label='RAW REALITY self-SNI + client fragment'
        fi
        jq --argjson socks_port "${RAW_FRAGMENT_TEST_PORT}" \
          --slurpfile fm "${INSTALL_DIR}/finalmask-fragment-canary.json" '
          .inbounds[0].port = $socks_port |
          .outbounds[0].streamSettings.finalmask = $fm[0]
        ' "${fragment_base_config}" >"${raw_fragment_config}"
        chmod 0600 "${raw_fragment_config}"
        validate_client_config "${raw_fragment_config}"
        run_transport_test "${fragment_label}" "${raw_fragment_test_container}" \
            "${RAW_FRAGMENT_TEST_PORT}" "${raw_fragment_config}"
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        validate_client_config "${xhttp_config}"
        run_transport_test 'TLS/XHTTP auto' "${xhttp_test_container}" \
            "${XHTTP_TEST_PORT}" "${xhttp_config}"
    fi
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
    local container state restarts reality_answers xhttp_answers external_answers
    local default_interface live_qdisc qdisc_drops tcp_rx_max tcp_tx_max hard_cpu_quotas=0 nano_cpus
    reality_answers="$(dig +short A "${REALITY_SNI}" | paste -sd, -)"
    reality_answers="${reality_answers:-unresolved}"
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        xhttp_answers="$(dig +short A "${XHTTP_SNI}" | paste -sd, -)"
        xhttp_answers="${xhttp_answers:-unresolved}"
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        external_answers="$(dig +short A "${EXTERNAL_REALITY_SNI}" | paste -sd, -)"
        external_answers="${external_answers:-unresolved}"
    fi
    ui_kv 'Install directory' "${INSTALL_DIR}"
    ui_kv 'Versions' "Panel 2.8.1 | Node 2.8.0 | Xray ${EXPECTED_XRAY_VERSION} | wizard ${SCRIPT_VERSION}"
    ui_section 'DNS' 'current public A answers'
    if [[ "${reality_answers}" == "${EDGE_IPV4}" ]]; then
        ui_status_row ok "${REALITY_SNI}" "${reality_answers}"
    else
        ui_status_row check "${REALITY_SNI}" "${reality_answers} (expected ${EDGE_IPV4})"
    fi
    if [[ "${ENABLE_XHTTP}" == 1 ]]; then
        if [[ "${xhttp_answers}" == "${EDGE_IPV4}" ]]; then
            ui_status_row ok "${XHTTP_SNI}" "${xhttp_answers}"
        else
            ui_status_row check "${XHTTP_SNI}" "${xhttp_answers} (expected ${EDGE_IPV4})"
        fi
    fi
    if [[ "${ENABLE_EXTERNAL_REALITY}" == 1 ]]; then
        if [[ "${external_answers}" != unresolved && "${external_answers}" != *"${EDGE_IPV4}"* ]]; then
            ui_status_row ok "External ${EXTERNAL_REALITY_SNI}" \
                "${external_answers}; regional CDN answer"
        else
            ui_status_row check "External ${EXTERNAL_REALITY_SNI}" \
                "${external_answers}; must resolve away from ${EDGE_IPV4}"
        fi
    fi
    default_interface="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
    live_qdisc="$(tc qdisc show dev "${default_interface}" 2>/dev/null | awk 'NR == 1 {print $2}')"
    qdisc_drops="$(tc -s qdisc show dev "${default_interface}" 2>/dev/null | \
        sed -nE 's/.*dropped ([0-9]+).*/\1/p' | head -n 1)"
    tcp_rx_max="$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')"
    tcp_tx_max="$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')"
    ui_section 'Host tuning' 'live kernel and scheduler state, not saved-file claims'
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
        ui_status_row ok 'Congestion control' 'bbr'
    else
        ui_status_row check 'Congestion control' "$(sysctl -n net.ipv4.tcp_congestion_control) (expected bbr)"
    fi
    if [[ "${live_qdisc}" == fq ]]; then
        ui_status_row ok "Queue ${default_interface}" "fq; drops ${qdisc_drops:-unknown}"
    else
        ui_status_row check "Queue ${default_interface}" "${live_qdisc:-unknown} (expected fq)"
    fi
    if [[ "${tcp_rx_max}" == 33554432 && "${tcp_tx_max}" == 33554432 ]]; then
        ui_status_row ok 'TCP autotuning ceilings' 'receive 32 MiB; send 32 MiB'
    else
        ui_status_row check 'TCP autotuning ceilings' "receive ${tcp_rx_max}; send ${tcp_tx_max}"
    fi
    if [[ "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 1 ]]; then
        ui_status_row ok 'TCP MTU probing' 'enabled'
    else
        ui_status_row check 'TCP MTU probing' 'disabled'
    fi
    for container in "${NODE_CONTAINER}" "${HAPROXY_CONTAINER}" "${CADDY_CONTAINER}"; do
        nano_cpus="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "${container}" 2>/dev/null || printf '0')"
        [[ "${nano_cpus}" =~ ^[0-9]+$ ]] || nano_cpus=0
        ((nano_cpus == 0)) || hard_cpu_quotas=$((hard_cpu_quotas + 1))
    done
    if ((hard_cpu_quotas == 0)); then
        ui_status_row ok 'Container CPU policy' 'burst allowed; weighted only under contention'
    else
        ui_status_row check 'Container CPU policy' "${hard_cpu_quotas} hard CFS quota(s) still active"
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
    [[ "${ENABLE_SELF_REALITY}" != 1 ]] || \
        status_tcp_listener "TCP/${RAW_BACKEND_PORT} self REALITY" "${RAW_BACKEND_PORT}" "${NODE_CONTAINER}"
    [[ "${ENABLE_EXTERNAL_REALITY}" != 1 ]] || \
        status_tcp_listener "TCP/${EXTERNAL_REALITY_BACKEND_PORT} external REALITY" \
            "${EXTERNAL_REALITY_BACKEND_PORT}" "${NODE_CONTAINER}"
    [[ "${ENABLE_XHTTP}" != 1 ]] || \
        status_tcp_listener "TCP/${XHTTP_BACKEND_PORT} XHTTP" "${XHTTP_BACKEND_PORT}" "${NODE_CONTAINER}"
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
        ui_status_row ok 'Panel control' "session established from ${PANEL_IPV4}"
    elif panel_control_observed; then
        ui_status_row ok 'Panel control' "successful exchange observed from ${PANEL_IPV4}"
    else
        ui_status_row check 'Panel control' 'no successful exchange observed'
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
    log 'Base tools are installed. The Node stage will preserve SSH and enable the generated UFW policy automatically.'
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
    [[ "$(normalize_yes_no_answer $'  Y\r ')" == y ]] || \
        die 'Yes/no input normalization rejected uppercase or terminal whitespace.'
    [[ "$(normalize_yes_no_answer $'\tNO  ')" == no ]] || \
        die 'Yes/no input normalization rejected uppercase or terminal whitespace.'
    original_install="${INSTALL_DIR}"
    temp_root="$(mktemp -d /tmp/remnawave-edge-selftest.XXXXXX)"
    selftest_cleanup() {
        find "${temp_root}" -depth -delete 2>/dev/null || true
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
    RAW_TAG='RW_A1B2C3D4_RAW_REALITY_SELF'
    EXTERNAL_REALITY_TAG='RW_A1B2C3D4_RAW_REALITY_EXTERNAL'
    XHTTP_TAG='RW_A1B2C3D4_XHTTP_TLS'
    HYSTERIA_TAG='RW_A1B2C3D4_HYSTERIA2'
    ENABLE_SELF_REALITY=1
    ENABLE_EXTERNAL_REALITY=1
    ENABLE_XHTTP=1
    ENABLE_HYSTERIA=1
    ENABLE_RAW_FRAGMENT=1
    FRAGMENT_REALITY='external'
    EXTERNAL_REALITY_TARGET='dl.google.com:443'
    EXTERNAL_REALITY_SNI='dl.google.com'
    CLIENT_FINGERPRINT='firefox'
    BLOCK_CLIENT_QUIC=1
    APPLY_TUNING=1
    NODE_CONTAINER='rw-edge-node-a1b2c3d4'
    HAPROXY_CONTAINER='rw-edge-haproxy-a1b2c3d4'
    CADDY_CONTAINER='rw-edge-caddy-a1b2c3d4'
    COMPOSE_PROJECT='rw-edge-a1b2c3d4'
    RAW_HOST_UUID='11111111-1111-4111-8111-111111111111'
    EXTERNAL_REALITY_HOST_UUID='66666666-6666-4666-8666-666666666666'
    RAW_FRAGMENT_HOST_UUID='55555555-5555-4555-8555-555555555555'
    XHTTP_HOST_UUID='22222222-2222-4222-8222-222222222222'
    HYSTERIA_HOST_UUID='44444444-4444-4444-8444-444444444444'
    EXTRA_HOST_UUIDS='33333333-3333-4333-8333-333333333333'
    pull_images
    generate_material
    write_state
    render_all_files
    ensure_node_env_placeholder
    validate_artifacts
    ENABLE_HYSTERIA=0
    HYSTERIA_HOST_UUID=''
    render_all_files
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
