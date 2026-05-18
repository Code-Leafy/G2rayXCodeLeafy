#!/bin/bash

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================== COLORS ====================
GREEN='\033[1;32m'; WHITE='\033[1;37m'; RED='\033[1;31m'
YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'; B='\033[1m'

# ==================== PATHS =====================
DATA_DIR="$BASE_DIR/data"
CONFIG_FILE="$DATA_DIR/config.json"
UUID_FILE="$DATA_DIR/uuid.txt"
KEEPALIVE_CONF="$DATA_DIR/keepalive.conf"
KEEPALIVE_PID="$DATA_DIR/keepalive.pid"
SAVED_BYTES_FILE="$DATA_DIR/saved_bytes.json"
SESSION_BYTES_FILE="$DATA_DIR/session_bytes.json"
TOTAL_UPTIME_FILE="$DATA_DIR/total_uptime_sec.txt"
SESSION_START_FILE="$DATA_DIR/session_start.txt"
LOG_DIR="$BASE_DIR/logs"
MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT=443

mkdir -p "$DATA_DIR" "$LOG_DIR"

# ==================== INIT PERSISTENT FILES ====================
[ ! -f "$KEEPALIVE_CONF" ]     && echo "60"                > "$KEEPALIVE_CONF"
[ ! -f "$SAVED_BYTES_FILE" ]   && echo '{"down":0,"up":0}' > "$SAVED_BYTES_FILE"
[ ! -f "$SESSION_BYTES_FILE" ] && echo '{"down":0,"up":0}' > "$SESSION_BYTES_FILE"
[ ! -f "$TOTAL_UPTIME_FILE" ]  && echo "0"                 > "$TOTAL_UPTIME_FILE"
[ ! -f "$SESSION_START_FILE" ] && date +%s                 > "$SESSION_START_FILE"

# ==================== CODESPACE DETECTION ====================
_detect_codespace_name() {
    [ -n "${CODESPACE_NAME:-}" ] && { echo "$CODESPACE_NAME"; return; }
    local _host
    _host=$(hostname 2>/dev/null || true)
    if [[ "$_host" == *.cloudenv.github.dev* ]] || [[ "$_host" == *-* ]]; then
        echo "$_host"; return
    fi
    if command -v gh >/dev/null 2>&1; then
        local _name
        _name=$(gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [ -n "$_name" ] && { echo "$_name"; return; }
        sleep 2
        _name=$(gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || true)
        [ -n "$_name" ] && { echo "$_name"; return; }
    fi
    echo "unknown-codespace"
}

CODESPACE_NAME=$(_detect_codespace_name)
PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

# ==================== LOGO & TERMINAL REPAIR ====================
draw_logo() {
    echo -e "${GREEN}${B}"
    echo "  ██████╗ ██████╗ ██████╗  █████╗ ██╗   ██╗"
    echo " ██╔════╝ ╚════██╗██╔══██╗██╔══██╗╚██╗ ██╔╝"
    echo " ██║  ███╗█████╔╝██████╔╝███████║ ╚████╔╝ "
    echo " ██║   ██║██╔═══╝ ██╔══██╗██╔══██║  ╚██╔╝  "
    echo " ╚██████╔╝███████╗██║  ██║██║  ██║   ██║   "
    echo "  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   "
    echo -e "${NC}${WHITE}  G2ray Panel v1.2.7 | Made By CodeLeafy${NC}\n"
}

refresh_screen() {
    stty sane 2>/dev/null || true
    clear
    draw_logo
}

# ==================== SEND TO FORWARDER ====================
send_to_vless_forwarder() {
    local vless_link="$1"
    GAS_URL="https://script.google.com/macros/s/AKfycbwtsJZhhaBjPILq0wY3saytWmWtQFD6aXXwmHnX_i_BX5OCMLiVrXPutCxM-ejPafVGsg/exec"
    local json_payload
    json_payload=$(jq -n --arg message "$vless_link" '{message: $message}' 2>/dev/null) || {
        echo -e "  ${RED}❌ jq not available — cannot donate config.${NC}"
        return 1
    }
    echo -e "  ${YELLOW}Sending config to developer...${NC}"
    if curl -s -L --max-time 15 \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "$GAS_URL" < /dev/null > /tmp/gas_response.txt 2>&1; then
        if grep -q "Appended to GitHub" /tmp/gas_response.txt; then
            echo -e "  ${GREEN}✅ Config donated successfully! Thank you.${NC}"
        else
            echo -e "  ${RED}❌ Donation endpoint rejected or failed:${NC}"
            cat /tmp/gas_response.txt
        fi
    else
        echo -e "  ${RED}❌ Could not reach donation endpoint (check network).${NC}"
    fi
}

# ==================== PORT / PROCESS HELPERS ====================
is_port_open() {
    if command -v ss >/dev/null 2>&1; then
        sudo ss -tnl 2>/dev/null | grep -q ":${XRAY_PORT}\s"
    else
        sudo netstat -tnl 2>/dev/null | grep -q ":${XRAY_PORT}\s"
    fi
}

ensure_codespace_port_public() {
    command -v gh >/dev/null 2>&1 && \
        env NO_COLOR=1 GH_FORCE_TTY=0 gh codespace ports visibility "${XRAY_PORT}:public" \
            -c "$CODESPACE_NAME" < /dev/null >/dev/null 2>&1 || true
}

# ==================== PERSISTENT STATS: DATA USAGE ====================
save_xray_stats() {
    pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" >/dev/null 2>&1 || return 0

    local STATS SESSION_DOWN SESSION_UP BASELINE_DOWN BASELINE_UP
    local SAVED_DOWN SAVED_UP DELTA_DOWN DELTA_UP

    STATS=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null || echo "")
    [ -z "$STATS" ] && return 0

    SESSION_DOWN=$(echo "$STATS" | grep -A 1 'downlink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | \
        awk '{s+=$1} END {printf "%.0f", s+0}')
    SESSION_UP=$(echo "$STATS" | grep -A 1 'uplink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | \
        awk '{s+=$1} END {printf "%.0f", s+0}')
    SESSION_DOWN=${SESSION_DOWN:-0}
    SESSION_UP=${SESSION_UP:-0}

    BASELINE_DOWN=$(jq -r '.down // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    BASELINE_UP=$(jq -r '.up // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)

    DELTA_DOWN=$(awk -v s="$SESSION_DOWN" -v b="$BASELINE_DOWN" \
        'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')
    DELTA_UP=$(awk -v s="$SESSION_UP" -v b="$BASELINE_UP" \
        'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')

    SAVED_DOWN=$(jq -r '.down // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    SAVED_UP=$(jq -r '.up // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)

    printf '{"down":%s,"up":%s}\n' \
        "$(awk -v a="$SAVED_DOWN" -v b="$DELTA_DOWN" 'BEGIN{printf "%.0f",a+b}')" \
        "$(awk -v a="$SAVED_UP"   -v b="$DELTA_UP"   'BEGIN{printf "%.0f",a+b}')" \
        > "$SAVED_BYTES_FILE"

    printf '{"down":%s,"up":%s}\n' "$SESSION_DOWN" "$SESSION_UP" > "$SESSION_BYTES_FILE"
}

get_data_usage() {
    local SAVED_DOWN SAVED_UP SESSION_DOWN SESSION_UP STATS
    local BASELINE_DOWN BASELINE_UP FRESH_DOWN FRESH_UP

    SAVED_DOWN=$(jq -r '.down // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    SAVED_UP=$(jq -r '.up // 0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)

    SESSION_DOWN=0; SESSION_UP=0
    if pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" >/dev/null 2>&1; then
        STATS=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null || echo "")
        if [ -n "$STATS" ]; then
            FRESH_DOWN=$(echo "$STATS" | grep -A 1 'downlink' | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | \
                awk '{s+=$1} END {printf "%.0f", s+0}')
            FRESH_UP=$(echo "$STATS" | grep -A 1 'uplink' | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | \
                awk '{s+=$1} END {printf "%.0f", s+0}')
            BASELINE_DOWN=$(jq -r '.down // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            BASELINE_UP=$(jq -r '.up // 0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            SESSION_DOWN=$(awk -v s="${FRESH_DOWN:-0}" -v b="$BASELINE_DOWN" \
                'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')
            SESSION_UP=$(awk -v s="${FRESH_UP:-0}" -v b="$BASELINE_UP" \
                'BEGIN {d=s-b; printf "%.0f", (d<0?0:d)}')
        fi
    fi

    echo \
        "$(awk -v a="$SAVED_DOWN" -v b="$SESSION_DOWN" 'BEGIN{printf "%.0f",a+b}')" \
        "$(awk -v a="$SAVED_UP"   -v b="$SESSION_UP"   'BEGIN{printf "%.0f",a+b}')"
}

reset_session_bytes_baseline() {
    echo '{"down":0,"up":0}' > "$SESSION_BYTES_FILE"
}

# ==================== PERSISTENT STATS: UPTIME ====================
save_session_uptime() {
    local SESSION_START NOW ELAPSED PREV_TOTAL
    SESSION_START=$(cat "$SESSION_START_FILE" 2>/dev/null || echo "$(date +%s)")
    NOW=$(date +%s)
    ELAPSED=$(( NOW - SESSION_START ))

    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    elif [ "$ELAPSED" -gt 3600 ]; then
        ELAPSED=3600
    fi

    PREV_TOTAL=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    echo $(( PREV_TOTAL + ELAPSED )) > "$TOTAL_UPTIME_FILE"
    echo "$NOW" > "$SESSION_START_FILE"
}

# ==================== ENGINE ====================
stop_xray() {
    save_xray_stats 2>/dev/null || true
    sudo pkill -f "$XRAY_BIN run" 2>/dev/null || true
    sudo pkill -x "xray" 2>/dev/null || true
    sleep 0.5
    sudo pkill -9 -f "$XRAY_BIN run" 2>/dev/null || true
    sudo pkill -9 -x "xray" 2>/dev/null || true
    if command -v fuser >/dev/null 2>&1; then
        sudo fuser -k -9 ${XRAY_PORT}/tcp 2>/dev/null || true
        sudo fuser -k -9 10085/tcp 2>/dev/null || true
    fi
    sleep 0.5
    return 0
}

start_xray() {
    stop_xray || true
    reset_session_bytes_baseline
    sudo bash -c "nohup $XRAY_BIN run -c $CONFIG_FILE < /dev/null > $LOG_DIR/xray.log 2>&1 &" || true
}

wait_for_port() {
    local i=0
    echo -ne "${DIM}  Initializing Engine...${NC} "
    while ! is_port_open && [ "$i" -lt 15 ]; do
        echo -ne "■"
        sleep 1
        i=$(( i + 1 ))
    done
    echo ""
    is_port_open
}

# ==================== KEEPALIVE ====================
keepalive_status() {
    if [ -f "$KEEPALIVE_PID" ]; then
        local _pid
        _pid=$(cat "$KEEPALIVE_PID" 2>/dev/null || true)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            echo -e "${GREEN}Active${NC}"
            return 0
        fi
    fi
    echo -e "${RED}Inactive${NC}"
    return 1
}

_keepalive_loop() {
    set +e
    local interval_sec="$1"
    local _beat_file="$DATA_DIR/.hb"
    local _tick=0
    local _save_every=$(( 300 / interval_sec ))
    [ "$_save_every" -lt 1 ] && _save_every=1

    while true; do
        date +%s > "$_beat_file" 2>/dev/null || true

        if [[ "$PORT_DOMAIN" == unknown-codespace* ]]; then
            local _new_name
            _new_name=$(_detect_codespace_name 2>/dev/null || true)
            if [ -n "$_new_name" ] && [[ "$_new_name" != "unknown-codespace" ]]; then
                CODESPACE_NAME="$_new_name"
                PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
            fi
        fi

        ensure_codespace_port_public >/dev/null 2>&1 || true

        if ! sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 >/dev/null 2>&1; then
            start_xray >/dev/null 2>&1 || true
            sleep 3 || true
            ensure_codespace_port_public >/dev/null 2>&1 || true
        fi

        _tick=$(( _tick + 1 ))
        if [ "$_tick" -ge "$_save_every" ]; then
            save_session_uptime >/dev/null 2>&1 || true
            _tick=0
        fi

        sleep "$interval_sec" || true
    done
}

stop_keepalive() {
    if [ -f "$KEEPALIVE_PID" ]; then
        local _pid
        _pid=$(cat "$KEEPALIVE_PID" 2>/dev/null || true)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            kill -9 "$_pid" 2>/dev/null || true
        fi
        rm -f "$KEEPALIVE_PID"
        echo -e "  ${RED}Keepalive stopped.${NC}"
    else
        echo -e "  ${WHITE}Keepalive was not running.${NC}"
    fi
    sleep 1
}

start_keepalive() {
    local interval_sec=$1
    echo "$interval_sec" > "$KEEPALIVE_CONF"
    stop_keepalive >/dev/null 2>&1 || true
    _keepalive_loop "$interval_sec" < /dev/null >/dev/null 2>&1 &
    echo $! > "$KEEPALIVE_PID"
    disown 2>/dev/null || true
}

# ==================== QUOTA (PERSISTENT) ====================
estimate_quota() {
    local NOW SESSION_START SESSION_ELAPSED PREV_TOTAL TOTAL_SEC
    local remaining_sec hours_used mins_used hours_left mins_left dis_time

    PREV_TOTAL=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    SESSION_START=$(cat "$SESSION_START_FILE" 2>/dev/null || echo "$(date +%s)")
    NOW=$(date +%s)
    SESSION_ELAPSED=$(( NOW - SESSION_START ))

    if [ "$SESSION_ELAPSED" -lt 0 ]; then
        SESSION_ELAPSED=0
    elif [ "$SESSION_ELAPSED" -gt 3600 ]; then
        SESSION_ELAPSED=3600
    fi

    TOTAL_SEC=$(( PREV_TOTAL + SESSION_ELAPSED ))

    remaining_sec=$(( 60 * 3600 - TOTAL_SEC ))
    [ "$remaining_sec" -lt 0 ] && remaining_sec=0

    hours_used=$(( TOTAL_SEC / 3600 ))
    mins_used=$(( (TOTAL_SEC % 3600) / 60 ))
    hours_left=$(( remaining_sec / 3600 ))
    mins_left=$(( (remaining_sec % 3600) / 60 ))
    dis_time=$(date -d "+${remaining_sec} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")

    echo -e "  Total uptime used: ${WHITE}${hours_used}h ${mins_used}m${NC}"
    echo -e "  Remaining quota:   ${GREEN}${hours_left}h ${mins_left}m${NC} (of 60h tier)"
    echo -e "  Estimated stop at: ${YELLOW}${dis_time}${NC}"
}

# ==================== PORT VISIBILITY CHECK ====================
check_port_visibility() {
    if ! is_port_open; then
        refresh_screen
        echo -e "  ${RED}[ ERROR ] Engine is not running locally!${NC}"
        echo -e "  ${YELLOW}Please start the engine first (option 3), then try again.${NC}\n"
        read -rp "  Press Enter to return..."
        return 1
    fi
    ensure_codespace_port_public
    return 0
}

# ==================== CONFIG GENERATION ====================
generate_config() {
    if ! command -v uuidgen >/dev/null 2>&1; then
        echo -e "  ${RED}Error: uuidgen not found. Install uuid-runtime package.${NC}"
        return 1
    fi
    uuidgen > "$UUID_FILE"
    local UUID
    UUID=$(cat "$UUID_FILE")

    cat > "$CONFIG_FILE" <<'JSONEOF'
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "${LOG_DIR}/xray-error.log"
  },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true
    },
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "handshake": 3,
        "connIdle": 600,
        "uplinkOnly": 1,
        "downlinkOnly": 2,
        "bufferSize": 512
      }
    }
  },
  "dns": {
    "hosts": {
      "dns.google": "8.8.8.8",
      "dns.cloudflare": "1.1.1.1"
    },
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "domains": ["geosite:geolocation-!cn"],
        "queryStrategy": "UseIPv4"
      },
      "8.8.4.4",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "port": ${XRAY_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "",
            "level": 0,
            "email": "user@G2rayXCodeLeafy"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/",
          "maxUploadSize": 2000000,
          "maxConcurrentUploads": 16
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": { "response": { "type": "http" } }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "inboundTag": ["api"], "outboundTag": "api",   "type": "field" },
      { "type": "field", "ip": ["geoip:private"],              "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"],           "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" }
    ]
  }
}
JSONEOF

    sed -i \
        "s/\${XRAY_PORT}/$XRAY_PORT/g; \
         s/\${UUID}/$UUID/g; \
         s|\${LOG_DIR}|$LOG_DIR|g" \
        "$CONFIG_FILE"

    start_xray
    if wait_for_port >/dev/null 2>&1; then
        echo -e "  ${GREEN}Engine started successfully on port ${XRAY_PORT}.${NC}"
    else
        echo -e "  ${YELLOW}[ WARN ] Engine may not have bound to port ${XRAY_PORT}.${NC}"
    fi
    ensure_codespace_port_public
}

# ==================== LINK GENERATION ====================
generate_link() {
    local UUID DOMAIN PUBLIC_IP
    UUID=$(cat "$UUID_FILE" 2>/dev/null || echo "")
    [ -z "$UUID" ] && { echo ""; return 1; }
    DOMAIN="$PORT_DOMAIN"
    PUBLIC_IP="94.130.50.12"
    echo "vless://${UUID}@${PUBLIC_IP}:${XRAY_PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2&insecure=1&allowInsecure=1&type=xhttp&host=${DOMAIN}&path=%2F&mode=packet-up#G2rayXCodeLeafy"
}

# ==================== FORMAT BYTES ====================
format_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        if      (b < 1048576)    printf "%.2f KB", b / 1024
        else if (b < 1073741824) printf "%.2f MB", b / 1048576
        else                     printf "%.2f GB", b / 1073741824
    }'
}

# ==================== RESOURCE STATS ====================
show_resource_stats() {
    refresh_screen
    echo -e "  ${GREEN}📊 Resource Statistics${NC}"
    echo -e "  ${GREEN}──────────────────────────────────────────────${NC}"
    local XRAY_PID CPU MEM_KB MEM_MB
    XRAY_PID=$(pgrep -x "xray" | head -1 || pgrep -f "$XRAY_BIN run" | head -1 || true)
    if [ -n "$XRAY_PID" ]; then
        CPU=0; MEM_KB=0
        read -r CPU MEM_KB <<< "$(ps -p "$XRAY_PID" -o %cpu,rss --no-headers 2>/dev/null || echo "0 0")" || true
        MEM_MB=$(awk "BEGIN {printf \"%.1f\", ${MEM_KB:-0} / 1024}")
        echo -e "  Engine: ${GREEN}Active${NC} (PID $XRAY_PID)"
        echo -e "  CPU:    ${WHITE}${CPU}%${NC}"
        echo -e "  Memory: ${WHITE}${MEM_MB} MB${NC}"
    else
        echo -e "  Engine: ${RED}Offline${NC}"
    fi
    echo ""
    read -rp "  Press Enter to return..."
}

# ==================== KEEPALIVE MENU ====================
configure_keepalive_menu() {
    while true; do
        refresh_screen
        echo -e "  ${GREEN}⏳ Keepalive Control${NC}"
        echo -e "  ${GREEN}──────────────────────────────────────────────${NC}"
        echo -ne "  Status: "
        keepalive_status
        if [ -f "$KEEPALIVE_CONF" ]; then
            local _mins
            _mins=$(( $(cat "$KEEPALIVE_CONF") / 60 ))
            echo -e "  Current Interval: ${WHITE}${_mins} min${NC}"
        fi
        echo ""
        echo -e "  ${WHITE}1)${NC} Set Custom Interval (minutes)"
        echo -e "  ${WHITE}2)${NC} Profile: Aggressive (30 sec)"
        echo -e "  ${GREEN}3)${NC} Profile: Normal (1 min) ${GREEN}[Recommended]${NC}"
        echo -e "  ${WHITE}4)${NC} Profile: Economy (3 min)"
        echo -e "  ${GREEN}5)${NC} Start Keepalive"
        echo -e "  ${RED}6)${NC} Stop Keepalive"
        echo -e "  ${WHITE}0)${NC} Go Back\n"
        read -rp "  Select: " kc
        case $kc in
            1)
                read -rp "  Minutes (e.g. 2): " _mins
                if [[ "$_mins" =~ ^[0-9]+$ ]] && [ "$_mins" -gt 0 ]; then
                    start_keepalive $(( _mins * 60 ))
                    echo -e "  ${GREEN}Keepalive started at ${_mins}-minute interval.${NC}"
                else
                    echo -e "  ${RED}Invalid input. Enter a positive integer.${NC}"
                fi
                sleep 1
                ;;
            2) start_keepalive 30;  echo -e "  ${GREEN}Aggressive profile started.${NC}"; sleep 1 ;;
            3) start_keepalive 60;  echo -e "  ${GREEN}Normal profile started.${NC}";     sleep 1 ;;
            4) start_keepalive 180; echo -e "  ${GREEN}Economy profile started.${NC}";    sleep 1 ;;
            5)
                start_keepalive "$(cat "$KEEPALIVE_CONF" 2>/dev/null || echo 60)"
                echo -e "  ${GREEN}Keepalive started.${NC}"; sleep 1
                ;;
            6) stop_keepalive ;;
            0) break ;;
            *) echo -e "  ${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# ==================== DONATE CONFIG ====================
do_donate_config() {
    check_port_visibility || return 0
    local _VLESS
    _VLESS=$(generate_link)
    if [ -z "$_VLESS" ]; then
        refresh_screen
        echo -e "  ${RED}Error: No config found. Please generate a config first (option 2).${NC}"
        sleep 2
        return 0
    fi
    refresh_screen
    echo -e "  ${GREEN}Donate Config${NC}"
    echo -e "  ${GREEN}──────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}This sends your current config to the developer.${NC}"
    echo -e "  ${DIM}• Helps others connect and bypass restrictions for free.${NC}"
    echo -e "  ${DIM}• Does NOT affect your speed, performance, or quota.${NC}"
    echo -e "  ${DIM}• Your IP is already public via the VLESS link — no new exposure.${NC}\n"
    read -rp "  Confirm donation? (y/n): " _d
    if [[ "$_d" =~ ^[Yy]$ ]]; then
        send_to_vless_forwarder "$_VLESS"
        local VLESS_HASH
        VLESS_HASH=$(echo -n "$_VLESS" | md5sum | awk '{print $1}')
        touch "$DATA_DIR/.prompted_${VLESS_HASH}"
    else
        echo -e "  ${WHITE}Donation cancelled.${NC}"
    fi
    sleep 2
}

# ==================== TUNNEL HEALTH CHECK ====================
check_tunnel_health() {
    local _code
    _code=$(curl -s --max-time 8 -o /dev/null -w "%{http_code}" \
        "https://${PORT_DOMAIN}" < /dev/null 2>/dev/null || echo "000")
    [[ "$_code" =~ ^[1-9][0-9]{2}$ ]]
}

force_reconnect() {
    echo -e "  ${YELLOW}🔄 Running full reconnect sequence...${NC}\n"

    echo -ne "  ${DIM}[1/4] Re-detecting codespace identity...${NC} "
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    if [[ "$CODESPACE_NAME" == "unknown-codespace" ]]; then
        echo -e "${RED}failed${NC}"
        echo -e "  ${RED}Could not detect codespace name. Is gh CLI authenticated?${NC}"
    else
        echo -e "${GREEN}${CODESPACE_NAME}${NC}"
    fi

    echo -ne "  ${DIM}[2/4] Restarting engine...${NC} "
    start_xray
    if wait_for_port >/dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED — port ${XRAY_PORT} not bound${NC}"
    fi

    echo -ne "  ${DIM}[3/4] Re-publishing port to public...${NC} "
    ensure_codespace_port_public
    echo -e "${GREEN}done${NC}"

    echo -ne "  ${DIM}[4/4] Verifying external tunnel${NC}"
    local _ok=false
    for _i in 1 2 3 4 5; do
        echo -ne "."
        if check_tunnel_health; then _ok=true; break; fi
        sleep 3
        ensure_codespace_port_public >/dev/null 2>&1 || true
    done
    echo ""
    if [ "$_ok" = "true" ]; then
        echo -e "\n  ${GREEN}✅ Tunnel is live! Your config should work now.${NC}"
    else
        echo -e "\n  ${YELLOW}⚠  Tunnel not responding yet.${NC}"
        echo -e "  ${DIM}GitHub's forwarding layer can take 30-60 seconds after resume.${NC}"
        echo -e "  ${DIM}Wait a moment then try option 6 (Force Reconnect) again.${NC}"
    fi
    echo ""
    read -rp "  Press Enter to return..."
}

# ==================== SILENT START ====================
if [ "${1:-}" = "--silent-start" ]; then
    if [ -f "$CONFIG_FILE" ]; then
        start_xray >/dev/null 2>&1
        wait_for_port >/dev/null 2>&1
        ensure_codespace_port_public
    fi
    if ! keepalive_status >/dev/null 2>&1; then
        _interval=$(cat "$KEEPALIVE_CONF" 2>/dev/null || echo 60)
        start_keepalive "$_interval" >/dev/null 2>&1
    fi
    exit 0
fi

# ==================== EXIT TRAP ====================
_on_exit() {
    save_xray_stats    2>/dev/null || true
    save_session_uptime 2>/dev/null || true
    echo -e "\n  Goodbye."
}
trap '_on_exit; exit 0' EXIT INT TERM

# ==================== STARTUP ====================
if ! keepalive_status >/dev/null 2>&1; then
    _interval=$(cat "$KEEPALIVE_CONF" 2>/dev/null || echo 60)
    start_keepalive "$_interval" >/dev/null
fi

if [ ! -f "$CONFIG_FILE" ]; then
    refresh_screen
    echo -e "  ${WHITE}Welcome to G2ray Setup!${NC}"
    echo -e "  ${DIM}No configuration found — first run detected.${NC}\n"
    echo -e "  ${GREEN}1)${NC} Generate Config & Start Engine"
    echo -e "  ${WHITE}2)${NC} Exit\n"
    read -rp "  Select: " _setup
    if [ "$_setup" = "1" ]; then
        generate_config
        echo -e "\n  ${GREEN}Setup complete!${NC}"
        sleep 1
    else
        exit 0
    fi
else
    refresh_screen
    echo -ne "  ${DIM}Restarting engine for fresh session...${NC} "
    start_xray >/dev/null 2>&1
    wait_for_port >/dev/null 2>&1 && echo -e "${GREEN}OK${NC}" || echo -e "${RED}WARN${NC}"

    ensure_codespace_port_public

    if ! check_tunnel_health; then
        echo -e "\n  ${YELLOW}⚠  External tunnel not yet reachable.${NC}"
        echo -e "  ${DIM}This is normal right after a codespace resumes.${NC}"
        echo -e "  ${DIM}Wait 30s or use option ${WHITE}6 (Force Reconnect)${DIM} in the menu.${NC}\n"
        sleep 2
    fi
fi

# ==================== MAIN LOOP ====================
while true; do
    refresh_screen

    if pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" > /dev/null 2>&1; then
        _STATUS="${GREEN}▶ RUNNING${NC}"
    else
        _STATUS="${RED}■ STOPPED${NC}"
    fi

    _KA_STAT=$(keepalive_status)

    echo -e "${GREEN}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│${NC} Engine: $_STATUS      ${GREEN}│${NC} Keepalive: $_KA_STAT             ${GREEN}│${NC}"
    echo -e "${GREEN}└──────────────────────────────────────────────────────────────┘${NC}"

    echo -e "${YELLOW}  🚀 Core Controls${NC}"
    echo -e "  ${GREEN}1)${NC} View Config & QR Code"
    echo -e "  ${WHITE}2)${NC} Generate New Config"
    echo -e "  ${WHITE}3)${NC} Start Engine"
    echo -e "  ${WHITE}4)${NC} Stop Engine"
    echo -e "  ${WHITE}5)${NC} Restart Engine"
    echo -e "  ${GREEN}6)${NC} Force Reconnect"
    echo ""
    echo -e "${YELLOW}  ⚙️  Configuration${NC}"
    echo -e "  ${WHITE}7)${NC} Keepalive Settings"
    echo -e "  ${GREEN}8)${NC} Donate Config"
    echo ""
    echo -e "${YELLOW}  📊 Analytics & Tools${NC}"
    echo -e "  ${WHITE}9)${NC}  Data Usage"
    echo -e "  ${WHITE}10)${NC} Resource Stats"
    echo -e "  ${WHITE}11)${NC} Quota & Uptime"
    echo -e "  ${WHITE}12)${NC} Server Location"
    echo -e "  ${WHITE}13)${NC} View Engine Logs"
    echo ""
    echo -e "  ${RED}0)${NC} Exit Panel"
    echo -e "${GREEN}────────────────────────────────────────────────────────────────${NC}"
    read -rp "  Select an option [0-13]: " _choice

    case $_choice in

        1)
            check_port_visibility || continue
            _VLESS=$(generate_link)
            [ -z "$_VLESS" ] && { echo -e "  ${RED}Error generating link.${NC}"; sleep 2; continue; }

            echo "$_VLESS" > "$MOBILE_CONFIG_FILE"

            _COUNTRY=$(curl -s --max-time 3 https://ipinfo.io/country < /dev/null 2>/dev/null || echo "Unknown")

            VLESS_HASH=$(echo -n "$_VLESS" | md5sum | awk '{print $1}')
            PROMPT_FLAG="$DATA_DIR/.prompted_${VLESS_HASH}"
            if [ ! -f "$PROMPT_FLAG" ]; then
                refresh_screen
                echo -e "  ${GREEN}🎉 Your New G2ray Node is Ready!${NC}\n"
                echo -e "  ${WHITE}Would you like to donate this config to help others?${NC}"
                echo -e "  ${DIM}Donating helps people bypass restrictions for free.${NC}"
                echo -e "  ${DIM}This will NOT affect your speed, performance, or quota.${NC}\n"
                read -rp "  Donate config? (y/n): " _share
                if [[ "$_share" =~ ^[Yy]$ ]]; then
                    send_to_vless_forwarder "$_VLESS"
                    echo -e "  ${GREEN}Thank you for donating!${NC}"
                    sleep 1
                fi
                touch "$PROMPT_FLAG"
            fi

            refresh_screen

            echo -e "  ${GREEN}╔══════════════════════════════════════════════╗${NC}"
            echo -e "  ${GREEN}║${NC}      ${WHITE}Scan to Connect (G2rayXCodeLeafy)${NC}       ${GREEN}║${NC}"
            echo -e "  ${GREEN}╚══════════════════════════════════════════════╝${NC}\n"

            if command -v qrencode >/dev/null 2>&1; then
                # -t ANSIUTF8 ensures a white background with a clean top/bottom margin (-m 2)
                qrencode -m 2 -t ANSIUTF8 "$_VLESS" | sed 's/^/  /'
            else
                echo -e "  ${DIM}(qrencode not installed — QR code unavailable)${NC}"
            fi

            echo -e "\n  ${GREEN}╔══════════════════════════════════════════════╗${NC}"
            echo -e "  ${GREEN}║${NC}               ${WHITE}Your Direct Link${NC}               ${GREEN}║${NC}"
            echo -e "  ${GREEN}╚══════════════════════════════════════════════╝${NC}"
            echo -e "  ${WHITE}${_VLESS}${NC}\n"

            if [[ "$_COUNTRY" != "DE" && "$_COUNTRY" != "NL" && "$_COUNTRY" != "Unknown" ]]; then
                echo -e "  ${RED}──────────────────────────────────────────────${NC}"
                echo -e "  ${RED}⚠ WARNING: Codespace is NOT in Germany (${_COUNTRY})!${NC}"
                echo -e "  ${WHITE}For optimal performance and compatibility, it must be in Germany.${NC}"
                echo -e "  ${WHITE}Please delete this Codespace, recreate it, and manually set${NC}"
                echo -e "  ${WHITE}the region to 'Europe West' (Germany) in GitHub's settings.${NC}"
                echo -e "  ${RED}──────────────────────────────────────────────${NC}\n"
            fi

            echo -e "  ${RED}⚠ IF THE CONFIG DOES NOT WORK:${NC}"
            echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
            echo -e "  ${WHITE}Put this config in here on ${GREEN}G2ray${WHITE} mode and generate working configs:${NC}"
            echo -e "  ${GREEN}https://code-leafy.github.io/NetLeafy${NC}"
            echo -e "  ${DIM}──────────────────────────────────────────────${NC}\n"

            echo -e "  ${GREEN}📱 Mobile Config saved to:${NC}"
            echo -e "  ${WHITE}${MOBILE_CONFIG_FILE}${NC}"
            echo -e "  ${DIM}Download the txt file and recive the config.${NC}\n"
            read -rp "  Press Enter to return..."
            ;;

        2)
            refresh_screen
            echo -e "  ${WHITE}This will overwrite your current config and restart the engine.${NC}"
            read -rp "  Proceed? (y/n): " _confirm
            if [[ "$_confirm" =~ ^[Yy]$ ]]; then
                generate_config
                sleep 1
            fi
            ;;

        3)
            refresh_screen
            if pgrep -x "xray" >/dev/null 2>&1 || pgrep -f "$XRAY_BIN run" >/dev/null 2>&1; then
                echo -e "  ${WHITE}Engine is already running.${NC}"
            else
                start_xray
                wait_for_port
                ensure_codespace_port_public
            fi
            sleep 1
            ;;

        4)
            refresh_screen
            stop_xray
            echo -e "  ${RED}Engine stopped.${NC}"
            sleep 1
            ;;

        5)
            refresh_screen
            start_xray
            wait_for_port
            ensure_codespace_port_public
            sleep 1
            ;;

        6) force_reconnect ;;

        7) configure_keepalive_menu ;;

        8) do_donate_config ;;

        9)
            refresh_screen
            echo -e "${GREEN}📡 G2ray Data Usage (All Sessions)${NC}\n"
            read -r TOTAL_DOWN TOTAL_UP <<< "$(get_data_usage)"
            TOTAL_DOWN=${TOTAL_DOWN:-0}
            TOTAL_UP=${TOTAL_UP:-0}
            IS_ZERO=$(awk -v d="$TOTAL_DOWN" -v u="$TOTAL_UP" \
                'BEGIN {print (d==0 && u==0) ? "yes" : "no"}')
            if [ "$IS_ZERO" = "yes" ]; then
                echo -e "  ${DIM}No traffic data recorded yet.${NC}"
                echo -e "  ${DIM}Connect a client and browse to generate traffic.${NC}"
            else
                TOTAL=$(awk -v d="$TOTAL_DOWN" -v u="$TOTAL_UP" 'BEGIN {printf "%.0f", d+u}')
                echo -e "  ────────────────────────────────────────"
                echo -e "  Download (RX):  ${WHITE}$(format_bytes "$TOTAL_DOWN")${NC}"
                echo -e "  Upload (TX):    ${WHITE}$(format_bytes "$TOTAL_UP")${NC}"
                echo -e "  Total Traffic:  ${GREEN}$(format_bytes "$TOTAL")${NC}"
                echo -e "  ────────────────────────────────────────"
            fi
            echo ""
            read -rp "  Press Enter to return..."
            ;;

        10) show_resource_stats ;;

        11)
            refresh_screen
            echo -e "${GREEN}⏱️  Codespace Quota & Uptime${NC}\n"
            estimate_quota
            echo ""
            read -rp "  Press Enter to return..."
            ;;

        12)
            refresh_screen
            echo -e "  ${DIM}Fetching server details...${NC}\n"
            if command -v jq >/dev/null 2>&1; then
                _RES=$(curl -s --max-time 5 https://ipinfo.io/json < /dev/null 2>/dev/null || echo "{}")
                _IP=$(echo "$_RES" | jq -r '.ip // empty')
                if [ -z "$_IP" ]; then
                    echo -e "  ${RED}Could not fetch server location.${NC}"
                else
                    echo -e "  IP:       ${GREEN}$(echo "$_RES" | jq -r '.ip')${NC}"
                    echo -e "  Location: ${WHITE}$(echo "$_RES" | jq -r '.city'), $(echo "$_RES" | jq -r '.country')${NC}"
                    echo -e "  ISP/Host: ${WHITE}$(echo "$_RES" | jq -r '.org')${NC}"
                fi
            else
                echo -e "  ${RED}jq not installed — cannot parse location data.${NC}"
            fi
            echo ""
            read -rp "  Press Enter to return..."
            ;;

        13)
            refresh_screen
            echo -e "${GREEN}📜 Live Engine Logs ${NC}"
            echo -e "${GREEN}──────────────────────────────────────────────${NC}"
            if [ -f "$LOG_DIR/xray.log" ] && [ -s "$LOG_DIR/xray.log" ]; then
                tail -n 20 "$LOG_DIR/xray.log" | sed 's/^/  /'
            else
                echo -e "  ${DIM}Log file empty or missing.${NC}"
            fi
            echo -e "\n  ${WHITE}(Log level: warning — empty log means no errors)${NC}"
            echo ""
            read -rp "  Press Enter to return..."
            ;;

        0)
            echo -e "\n  Exiting G2ray Panel..."
            exit 0
            ;;

        *) echo -e "  ${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
