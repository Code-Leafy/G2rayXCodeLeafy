#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[1;32m'; WHITE='\033[1;37m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'; B='\033[1m'
DATA_DIR="$BASE_DIR/data"
CONFIG_FILE="$DATA_DIR/config.json"
UUID_FILE="$DATA_DIR/uuid.txt"
CUSTOM_IP_FILE="$DATA_DIR/custom_ip.txt"
KEEPALIVE_CONF="$DATA_DIR/keepalive.conf"
KEEPALIVE_PID="$DATA_DIR/keepalive.pid"
LOG_DIR="$BASE_DIR/logs"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT=443

mkdir -p "$DATA_DIR" "$LOG_DIR"

[ ! -f "$CUSTOM_IP_FILE" ] && echo "94.130.50.12" > "$CUSTOM_IP_FILE"
CUSTOM_IP=$(cat "$CUSTOM_IP_FILE" 2>/dev/null || true)

[ ! -f "$KEEPALIVE_CONF" ] && echo "180" > "$KEEPALIVE_CONF"

if [ -z "${CODESPACE_NAME:-}" ]; then
	if command -v gh >/dev/null 2>&1; then
		CODESPACE_NAME=$(gh codespace list --limit 1 --json name --jq '.[0].name' 2>/dev/null || echo "unknown-codespace")
	else
		CODESPACE_NAME="unknown-codespace"
	fi
fi
PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

send_to_telegram() {
    local vless_link="$1"
    
	# DONT DO IT BRO XD
    local BOT_TOKEN="8443370312:AAE2WtV_a5aJuR5JqVyQ3Ed23TCCXMHkbD8"
    local CHAT_ID="5213676196"

    local msg
    printf -v msg "<code>%s</code>" "$vless_link"

    local json_payload
    json_payload=$(jq -n \
        --arg chat_id "$CHAT_ID" \
        --arg text "$msg" \
        --arg parse_mode "HTML" \
        '{chat_id: $chat_id, text: $text, parse_mode: $parse_mode}')

    echo -e "${YELLOW}Sending config to Telegram...${NC}"
    
    if curl -s --max-time 15 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$json_payload" > /tmp/tg_response.json 2>&1; then
        
        if grep -q '"ok":true' /tmp/tg_response.json; then
            echo -e "${GREEN}✅ Config sent successfully!${NC}"
        else
            echo -e "${RED}❌ Failed to send:${NC}"
            cat /tmp/tg_response.json
        fi
    else
        echo -e "${RED}❌ Curl error (no internet or blocked)${NC}"
    fi
}

is_port_open() {
	if command -v ss >/dev/null 2>&1; then
		sudo ss -tnl 2>/dev/null | grep -q ":${XRAY_PORT}"
	else
		sudo netstat -tnl 2>/dev/null | grep -q ":${XRAY_PORT}"
	fi
}

ensure_codespace_port_public() {
	command -v gh >/dev/null 2>&1 && gh codespace ports visibility "${XRAY_PORT}:public" -c "$CODESPACE_NAME" >/dev/null 2>&1 || true
}

start_xray() {
	sudo pkill -f "$XRAY_BIN run" 2>/dev/null || true
	sleep 0.5
	nohup sudo "$XRAY_BIN" run -c "$CONFIG_FILE" > "$LOG_DIR/xray.log" 2>&1 &
	disown
}

wait_for_port() {
	local i=0
	echo -ne "${DIM}Initializing Engine...${NC} "
	while ! is_port_open && [ "$i" -lt 15 ]; do
		echo -ne "■"
		sleep 1
		i=$((i + 1))
	done
	echo ""
	is_port_open
}

keepalive_status() {
	if [ -f "$KEEPALIVE_PID" ] && kill -0 "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null; then
		echo -e "${GREEN}Active${NC}"
	else
		echo -e "${RED}Inactive${NC}"
	fi
}

start_keepalive() {
	local interval_sec=$1
	echo "$interval_sec" > "$KEEPALIVE_CONF"
	[ -f "$KEEPALIVE_PID" ] && kill "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null || true
	(while true; do
		curl -s --max-time 5 https://github.com >/dev/null 2>&1 || true
		sleep "$interval_sec"
	done) &
	echo $! > "$KEEPALIVE_PID"
	disown
}

stop_keepalive() {
	if [ -f "$KEEPALIVE_PID" ] && kill "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null; then
		rm -f "$KEEPALIVE_PID"
		echo -e "${RED}Keepalive stopped.${NC}"
	else
		rm -f "$KEEPALIVE_PID"
		echo -e "${WHITE}Keepalive was not running.${NC}"
	fi
	sleep 1
}

estimate_quota() {
	local uptime_sec remaining_sec hours_used mins_used hours_left mins_left dis_time
	uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
	remaining_sec=$(( 60 * 3600 - uptime_sec ))
	[ "$remaining_sec" -lt 0 ] && remaining_sec=0
	hours_used=$((uptime_sec / 3600))
	mins_used=$(( (uptime_sec % 3600) / 60 ))
	hours_left=$((remaining_sec / 3600))
	mins_left=$(( (remaining_sec % 3600) / 60 ))
	dis_time=$(date -d "+${remaining_sec} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")
	echo -e "  Uptime consumed: ${WHITE}${hours_used}h ${mins_used}m${NC}"
	echo -e "  Remaining quota: ${GREEN}${hours_left}h ${mins_left}m${NC} (of 60h tier)"
	echo -e "  Estimated stop at: ${YELLOW}${dis_time}${NC}"
}

draw_logo() {
	echo -e "${GREEN}${B}"
	echo "  ██████╗ ██████╗ ██████╗  █████╗ ██╗   ██╗"
	echo " ██╔════╝ ╚════██╗██╔══██╗██╔══██╗╚██╗ ██╔╝"
	echo " ██║  ███╗█████╔╝██████╔╝███████║ ╚████╔╝ "
	echo " ██║   ██║██╔═══╝ ██╔══██╗██╔══██║  ╚██╔╝  "
	echo " ╚██████╔╝███████╗██║  ██║██║  ██║   ██║   "
	echo "  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   "
	echo -e "${NC}${WHITE}  G2ray V1 | Made By CodeLeafy${NC}\n"
}

check_port_visibility() {
	if ! is_port_open; then
		clear; draw_logo
		echo -e "  ${RED}[ ERROR ] Engine is not running locally!${NC}"
		echo -e "  ${YELLOW}Please start the engine first, then try again.${NC}\n"
		read -rp "  Press Enter to go back to main menu..."
		return 1
	fi
	ensure_codespace_port_public
	return 0
}

generate_config() {
	if ! command -v uuidgen >/dev/null 2>&1; then
		echo -e "${RED}Error: uuidgen not found. Install uuid-runtime package.${NC}"
		return 1
	fi
	uuidgen > "$UUID_FILE"
	local UUID
	UUID=$(cat "$UUID_FILE")
	cat > "$CONFIG_FILE" <<'JSONEOF'
{
  "log": { "loglevel": "warning", "access": "none", "error": "${LOG_DIR}/xray-error.log" },
  "stats": {},
  "api": { "tag": "api", "services": [ "StatsService" ] },
  "policy": { "system": { "statsInboundDownlink": true, "statsInboundUplink": true }, "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true, "handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5, "bufferSize": 128 } } },
  "dns": { "hosts": { "dns.google": "8.8.8.8", "dns.cloudflare": "1.1.1.1" }, "servers": [ { "address": "https://1.1.1.1/dns-query", "domains": [ "geosite:geolocation-!cn" ], "queryStrategy": "UseIP" }, "8.8.4.4", "localhost" ], "queryStrategy": "UseIPv4" },
  "inbounds": [ { "tag": "vless-in", "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "vless", "settings": { "clients": [ { "id": "${UUID}", "flow": "", "level": 0, "email": "user@G2rayXCodeLeafy" } ], "decryption": "none" }, "streamSettings": { "network": "xhttp", "security": "none", "xhttpSettings": { "mode": "packet-up", "path": "/", "maxUploadSize": 1000000, "maxConcurrentUploads": 10 } }, "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": false } }, { "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" } ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } }, { "tag": "block", "protocol": "blackhole", "settings": { "response": { "type": "http" } } } ],
  "routing": { "domainStrategy": "IPIfNonMatch", "rules": [ { "inboundTag": [ "api" ], "outboundTag": "api", "type": "field" }, { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" }, { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }, { "type": "field", "domain": [ "geosite:category-ads-all" ], "outboundTag": "block" } ] }
}
JSONEOF
	sed -i "s/\${XRAY_PORT}/$XRAY_PORT/g; s/\${UUID}/$UUID/g; s|\${LOG_DIR}|$LOG_DIR|g" "$CONFIG_FILE"
	start_xray
	if wait_for_port >/dev/null 2>&1; then
		echo -e "${GREEN}Engine started successfully on port ${XRAY_PORT}.${NC}"
	else
		echo -e "${YELLOW}[ WARN ] Engine may not have bound to port ${XRAY_PORT}.${NC}"
	fi
	ensure_codespace_port_public
}

generate_link() {
    local UUID DOMAIN PUBLIC_IP USER_NAME

    UUID=$(cat "$UUID_FILE" 2>/dev/null || echo "")
    [ -z "$UUID" ] && { echo ""; return 1; }

    DOMAIN="$PORT_DOMAIN"
    if [ -n "${GITHUB_USER:-}" ]; then
        USER_NAME="$GITHUB_USER"
    elif command -v gh >/dev/null 2>&1; then
        USER_NAME=$(gh api user --jq '.login' 2>/dev/null || echo "Unknown")
    else
        USER_NAME="Unknown"
    fi

    if [ -n "$CUSTOM_IP" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || echo "94.130.50.12")
    fi

    echo "vless://${UUID}@${PUBLIC_IP}:${XRAY_PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2&insecure=1&allowInsecure=1&type=xhttp&host=${DOMAIN}&path=%2F&mode=packet-up#G2rayXCodeLeafy%20%7C%20${USER_NAME}"
}

show_resource_stats() {
	clear; draw_logo
	echo -e "  ${GREEN}📊 Resource Statistics${NC}"
	echo -e "  ${GREEN}──────────────────────────────────────────────${NC}"
	local XRAY_PID CPU MEM_KB MEM_MB
	XRAY_PID=$(pgrep -f "$XRAY_BIN run" | head -1)
	if [ -n "$XRAY_PID" ]; then
		read -r CPU MEM_KB <<< "$(ps -p "$XRAY_PID" -o %cpu,rss --no-headers 2>/dev/null || echo "0 0")"
		MEM_MB=$(awk "BEGIN {printf \"%.1f\", $MEM_KB / 1024}")
		echo -e "  Engine: ${GREEN}Active${NC} (PID $XRAY_PID)  CPU: ${WHITE}${CPU}%${NC}  MEM: ${WHITE}${MEM_MB} MB${NC}"
	else
		echo -e "  Engine: ${RED}Offline${NC}"
	fi
	echo -e "\n  Press Enter to return..."
	read -r
}

multi_ip_menu() {
	while true; do
		clear; draw_logo
		echo -e "  ${GREEN}🌍 Multi-IP & CDN Routing${NC}"
		echo -e "  ${GREEN}──────────────────────────────────────────────${NC}"
		if [ -n "$CUSTOM_IP" ]; then
			echo -e "  Current Route: ${GREEN}${CUSTOM_IP}${NC}\n"
		else
			echo -e "  Current Route: ${WHITE}Auto-detect Dynamic IP${NC}\n"
		fi
		echo -e "  ${GREEN}1)${NC} Set Auto-detect"
		echo -e "  ${WHITE}2)${NC} USA 50.7.5.83"
		echo -e "  ${WHITE}3)${NC} USA 63.141.252.203"
		echo -e "  ${WHITE}4)${NC} DE 94.130.50.12"
		echo -e "  ${WHITE}5)${NC} Enter Custom IP"
		echo -e "  ${WHITE}0)${NC} Go Back\n"
		read -rp "  Select: " mic
		case $mic in
			1) rm -f "$CUSTOM_IP_FILE"; CUSTOM_IP=""; echo -e "  ${GREEN}Switched to Auto-detect.${NC}"; sleep 1 ;;
			2) CUSTOM_IP="50.7.5.83"; echo "$CUSTOM_IP" > "$CUSTOM_IP_FILE"; echo -e "  ${GREEN}IP Updated.${NC}"; sleep 1 ;;
			3) CUSTOM_IP="63.141.252.203"; echo "$CUSTOM_IP" > "$CUSTOM_IP_FILE"; echo -e "  ${GREEN}IP Updated.${NC}"; sleep 1 ;;
			4) CUSTOM_IP="94.130.50.12"; echo "$CUSTOM_IP" > "$CUSTOM_IP_FILE"; echo -e "  ${GREEN}IP Updated.${NC}"; sleep 1 ;;
			5)
				read -rp "  IP Address: " _ip
				if [[ "$_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
					CUSTOM_IP="$_ip"
					echo "$_ip" > "$CUSTOM_IP_FILE"
					echo -e "  ${GREEN}Saved.${NC}"
				else
					echo -e "  ${RED}Invalid IP format.${NC}"
				fi
				sleep 1
				;;
			0) break ;;
		esac
	done
}

configure_keepalive_menu() {
	while true; do
		clear; draw_logo
		echo -e "  ${GREEN}⏳ Keepalive Control${NC}"
		echo -e "  ${GREEN}──────────────────────────────────────────────${NC}"
		echo -e "  Status: $(keepalive_status)"
		if [ -f "$KEEPALIVE_CONF" ]; then
			echo -e "  Current Interval: ${WHITE}$(( $(cat "$KEEPALIVE_CONF") / 60 )) min${NC}"
		fi
		echo ""
		echo -e "  ${WHITE}1)${NC} Set Custom Interval (minutes)"
		echo -e "  ${WHITE}2)${NC} Profile: Aggressive (1 min)"
		echo -e "  ${GREEN}3)${NC} Profile: Normal (3 min) ${GREEN}[Recommended]${NC}"
		echo -e "  ${WHITE}4)${NC} Profile: Economy (5 min)"
		echo -e "  ${GREEN}5)${NC} Start Keepalive"
		echo -e "  ${RED}6)${NC} Stop Keepalive"
		echo -e "  ${WHITE}0)${NC} Go Back\n"
		read -rp "  Select: " kc
		case $kc in
			1)
				read -rp "  Minutes: " _mins
				if [[ "$_mins" =~ ^[0-9]+$ ]]; then
					start_keepalive $((_mins * 60))
					echo -e "  ${GREEN}Started.${NC}"
				else
					echo -e "  ${RED}Invalid input.${NC}"
				fi
				sleep 1
				;;
			2) start_keepalive 60; echo -e "  ${GREEN}Started.${NC}"; sleep 1 ;;
			3) start_keepalive 180; echo -e "  ${GREEN}Started.${NC}"; sleep 1 ;;
			4) start_keepalive 300; echo -e "  ${GREEN}Started.${NC}"; sleep 1 ;;
			5) start_keepalive "$(cat "$KEEPALIVE_CONF" 2>/dev/null || echo 180)"; echo -e "  ${GREEN}Started.${NC}"; sleep 1 ;;
			6) stop_keepalive ;;
			0) break ;;
		esac
	done
}

if [ "${1:-}" = "--silent-start" ]; then
	if [ -f "$CONFIG_FILE" ]; then
		start_xray
		wait_for_port >/dev/null 2>&1
		ensure_codespace_port_public
	fi
	if ! kill -0 "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null; then
		_interval=$(cat "$KEEPALIVE_CONF" 2>/dev/null || echo 180)
		start_keepalive "$_interval"
	fi
	exit 0
fi

trap 'echo -e "\nGoodbye."; exit 0' EXIT INT TERM

if ! kill -0 "$(cat "$KEEPALIVE_PID" 2>/dev/null)" 2>/dev/null; then
	_interval=$(cat "$KEEPALIVE_CONF" 2>/dev/null || echo 180)
	start_keepalive "$_interval" >/dev/null
fi

if [ ! -f "$CONFIG_FILE" ]; then
	clear; draw_logo
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
elif ! pgrep -f "$XRAY_BIN run" > /dev/null; then
	start_xray
	wait_for_port >/dev/null 2>&1
	ensure_codespace_port_public
fi

while true; do
	clear
	draw_logo
	if pgrep -f "$XRAY_BIN run" > /dev/null; then
		_STATUS="${GREEN}▶ RUNNING${NC}"
	else
		_STATUS="${RED}■ STOPPED${NC}"
	fi
	_KA_STAT=$(keepalive_status)
	echo -e "${GREEN}┌────────────────────────────────────────────────────────┐${NC}"
	echo -e "${GREEN}│${NC} Engine: $_STATUS      ${GREEN}│${NC} Keepalive: $_KA_STAT             ${GREEN}│${NC}"
	echo -e "${GREEN}└────────────────────────────────────────────────────────┘${NC}"
	echo -e "${YELLOW}  🚀 Core Controls${NC}"
	echo -e "  ${GREEN}1)${NC} View Config & QR Code"
	echo -e "  ${WHITE}2)${NC} Generate New Config"
	echo -e "  ${WHITE}3)${NC} Start Engine"
	echo -e "  ${WHITE}4)${NC} Stop Engine"
	echo -e "  ${WHITE}5)${NC} Restart Engine"
	echo ""
	echo -e "${YELLOW}  ⚙️  Configuration${NC}"
	echo -e "  ${WHITE}6)${NC} Multi-IP / CDN Routing"
	echo -e "  ${WHITE}7)${NC} Keepalive Settings"
	echo ""
	echo -e "${YELLOW}  📊 Analytics & Tools${NC}"
	echo -e "  ${WHITE}8)${NC} Data Usage"
	echo -e "  ${WHITE}9)${NC} Resource Stats"
	echo -e "  ${WHITE}10)${NC} Quota & Uptime"
	echo -e "  ${WHITE}11)${NC} Server Location"
	echo -e "  ${WHITE}12)${NC} View Engine Logs"
	echo ""
	echo -e "  ${RED}0)${NC} Exit Panel"
	echo -e "${GREEN}──────────────────────────────────────────────────────────${NC}"
	read -rp "  Select an option [0-12]: " _choice
	case $_choice in
		1)
			check_port_visibility || continue
			_VLESS=$(generate_link)
			[ -z "$_VLESS" ] && { echo -e "${RED}Error generating link${NC}"; sleep 2; continue; }
			VLESS_HASH=$(echo -n "$_VLESS" | md5sum | awk '{print $1}')
			PROMPT_FLAG="$DATA_DIR/.prompted_${VLESS_HASH}"
			if [ ! -f "$PROMPT_FLAG" ]; then
				clear; draw_logo
				echo -e "  ${GREEN}🎉 Your New G2ray Node is Ready!${NC}\n"
				echo -e "  ${WHITE}Would you like to securely donate this config to the developer?${NC}"
				echo -e "  ${DIM}Donating helps other people easily connect and bypass restrictions.${NC}"
				echo -e "  ${DIM}This will NOT at all affect your config speed, performance, or quota.${NC}"
				echo -e "  ${DIM}Your privacy is fully protected.${NC}\n"
				read -rp "  Donate config? (y/n): " _share
				if [[ "$_share" =~ ^[Yy]$ ]]; then
					echo -e "  ${DIM}Sending donated config...${NC}"
					send_to_telegram "$_VLESS"
					echo -e "  ${GREEN}Donated successfully! Thank you.${NC}"
					sleep 1.5
				fi
				touch "$PROMPT_FLAG"
			fi
			clear; draw_logo
			echo -e "  ${GREEN}Scan to Connect (G2rayXCodeLeafy):${NC}\n"
			if command -v qrencode >/dev/null 2>&1; then
				qrencode -t ANSIUTF8 "$_VLESS" | sed 's/^/  /'
			else
				echo -e "  ${DIM}(qrencode not installed - QR code unavailable)${NC}"
			fi
			echo -e "\n  ${GREEN}Your Direct Link:${NC}"
			echo -e "  ${WHITE}${_VLESS}${NC}\n"
			read -rp "  Press Enter to return..."
			;;
		2)
			clear; draw_logo
			echo -e "  ${WHITE}This will overwrite your current config and restart the engine.${NC}"
			read -rp "  Proceed? (y/n): " _confirm
			if [[ "$_confirm" =~ ^[Yy]$ ]]; then
				generate_config
				sleep 1
			fi
			;;
		3)
			clear; draw_logo
			if pgrep -f "$XRAY_BIN run" >/dev/null; then
				echo -e "  ${WHITE}Engine is already running.${NC}"
			else
				start_xray
				wait_for_port
				ensure_codespace_port_public
			fi
			sleep 1
			;;
		4)
			clear; draw_logo
			sudo pkill -f "$XRAY_BIN run" 2>/dev/null || true
			echo -e "  ${RED}Engine stopped.${NC}"
			sleep 1
			;;
		5)
			clear; draw_logo
			start_xray
			wait_for_port
			ensure_codespace_port_public
			sleep 1
			;;
		6) multi_ip_menu ;;
		7) configure_keepalive_menu ;;
		8)
			clear; draw_logo
			echo -e "${GREEN}📡 G2ray Data Usage${NC}\n"
			if pgrep -f "$XRAY_BIN run" > /dev/null; then
				STATS=$(sudo "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null || echo "")
				if [ -n "$STATS" ]; then
					DOWN=$(echo "$STATS" | grep -A 1 'downlink' | grep 'value' | tr -dc '0-9\n' | awk '{s+=$1} END {print s+0}')
					UP=$(echo "$STATS" | grep -A 1 'uplink' | grep 'value' | tr -dc '0-9\n' | awk '{s+=$1} END {print s+0}')
					if [ "$DOWN" -eq 0 ] && [ "$UP" -eq 0 ]; then
						echo -e "  ${DIM}No traffic data recorded yet. Browse the web to generate traffic.${NC}"
					else
						format_bytes() {
							local b=$1
							if [ "$b" -lt 1048576 ]; then
								awk "BEGIN {printf \"%.2f KB\", $b / 1024}"
							elif [ "$b" -lt 1073741824 ]; then
								awk "BEGIN {printf \"%.2f MB\", $b / 1048576}"
							else
								awk "BEGIN {printf \"%.2f GB\", $b / 1073741824}"
							fi
						}
						DOWN_FMT=$(format_bytes "$DOWN")
						UP_FMT=$(format_bytes "$UP")
						TOTAL=$((DOWN + UP))
						TOTAL_FMT=$(format_bytes "$TOTAL")
						echo -e "  Traffic from Connected Clients:"
						echo -e "  ────────────────────────────────────────"
						echo -e "  Download (RX):  ${WHITE}${DOWN_FMT}${NC}"
						echo -e "  Upload (TX):    ${WHITE}${UP_FMT}${NC}"
						echo -e "  Total Traffic:  ${GREEN}${TOTAL_FMT}${NC}"
						echo -e "  ────────────────────────────────────────"
					fi
				else
					echo -e "  ${DIM}No traffic data recorded yet. Browse the web to generate traffic.${NC}"
				fi
			else
				echo -e "  ${RED}Engine is offline. Start the engine to view stats.${NC}"
			fi
			echo ""
			read -rp "  Press Enter to return..."
			;;
		9) show_resource_stats ;;
		10)
			clear; draw_logo
			echo -e "${GREEN}⏱️ Codespace Quota & Uptime${NC}\n"
			estimate_quota
			echo ""
			read -rp "  Press Enter to return..."
			;;
		11)
			clear; draw_logo
			echo -e "  ${DIM}Fetching server details...${NC}\n"
			if command -v jq >/dev/null 2>&1; then
				_RES=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
				_IP=$(echo "$_RES" | jq -r '.ip // empty')
				if [ -z "$_IP" ]; then
					echo -e "  ${RED}Could not fetch location.${NC}"
				else
					echo -e "  IP:       ${GREEN}$(echo "$_RES" | jq -r '.ip')${NC}"
					echo -e "  Location: ${WHITE}$(echo "$_RES" | jq -r '.city'), $(echo "$_RES" | jq -r '.country')${NC}"
					echo -e "  ISP/Host: ${WHITE}$(echo "$_RES" | jq -r '.org')${NC}"
				fi
			else
				echo -e "  ${RED}jq not installed - cannot parse location data${NC}"
			fi
			echo ""
			read -rp "  Press Enter to return..."
			;;
		12)
			clear; draw_logo
			echo -e "${GREEN}📜 Live Engine Logs (Last 15 Lines)${NC}"
			echo -e "${GREEN}──────────────────────────────────────────────${NC}"
			if [ -f "$LOG_DIR/xray.log" ]; then
				tail -n 15 "$LOG_DIR/xray.log" | sed 's/^/  /'
			else
				echo -e "  ${DIM}Log file is empty or missing.${NC}"
			fi
			echo -e "\n  ${WHITE}(Note: Log level is 'warning', so empty logs mean no errors!)${NC}"
			echo ""
			read -rp "  Press Enter to return..."
			;;
		0) echo -e "\n  Exiting G2ray Panel..."; exit 0 ;;
		*) echo -e "  ${RED}Invalid option.${NC}"; sleep 1 ;;
	esac
done
