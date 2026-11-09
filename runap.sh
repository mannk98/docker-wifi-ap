#!/bin/bash

#===============================================================================
# Script: WiFi Access Point Setup - Docker & Host Compatible
# Description: Tự động cấu hình USB WiFi thành Access Point với auto-detect
#===============================================================================

# --- Cấu hình (Hỗ trợ truyền qua biến môi trường cho Docker) ---
WIFI_IFACE="${WIFI_IFACE:-auto}"
ETH_IFACE="${ETH_IFACE:-auto}"
AP_IP="${AP_IP:-192.168.50.1}"
AP_SUBNET="${AP_SUBNET:-192.168.50.0/24}"
DHCP_START="${DHCP_START:-192.168.50.10}"
DHCP_END="${DHCP_END:-192.168.50.100}"
DHCP_LEASE="${DHCP_LEASE:-12h}"

# WiFi Settings
WIFI_SSID="${WIFI_SSID:-matinhieu}"
WIFI_PASSWORD="${WIFI_PASSWORD:-88888888}"
WIFI_HIDDEN="${WIFI_HIDDEN:-0}"    # 1 = ẩn, 0 = hiện

# Auto-detect settings (sẽ được override bởi detection nếu để auto)
WIFI_BAND="${WIFI_BAND:-auto}"     # auto, 2.4ghz, 5ghz
WIFI_CHANNEL="${WIFI_CHANNEL:-auto}"
WIFI_HW_MODE="${WIFI_HW_MODE:-g}"

# Country code for regulatory domain
COUNTRY_CODE="${COUNTRY_CODE:-US}" # VN cho Vietnam, US ít giới hạn hơn

# Chế độ chạy không tương tác (1 = dùng cho Docker/automation, 0 = hỏi xác nhận)
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

# File paths
DNSMASQ_CONF="/tmp/dnsmasq-ap.conf"
HOSTAPD_CONF="/tmp/hostapd-ap.conf"
DNSMASQ_PID="/tmp/dnsmasq-ap.pid"
HOSTAPD_PID="/tmp/hostapd-ap.pid"
DNSMASQ_LEASES="/var/lib/misc/dnsmasq.leases"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#===============================================================================
# Functions
#===============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Script này cần chạy với quyền root (hoặc container privileged/NET_ADMIN)!"
        log_info "Sử dụng: sudo $0"
        exit 1
    fi
}

# Tự động phát hiện interface nếu để "auto" hoặc interface cấu hình không tồn tại
resolve_interfaces() {
    if [ "$WIFI_IFACE" = "auto" ] || ! ip link show "$WIFI_IFACE" &> /dev/null; then
        local detected_wifi
        # Ưu tiên USB WiFi dongle (thường có prefix wlx...) trước, nếu không có mới lấy card WiFi bất kỳ
        detected_wifi=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | grep '^wlx' | head -1)
        if [ -z "$detected_wifi" ]; then
            detected_wifi=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)
        fi
        if [ -n "$detected_wifi" ]; then
            if [ "$WIFI_IFACE" != "auto" ]; then
                log_warn "Interface $WIFI_IFACE không tồn tại, tự động chuyển sang: $detected_wifi"
            else
                log_info "Tự động phát hiện WiFi interface: $detected_wifi"
            fi
            WIFI_IFACE="$detected_wifi"
        fi
    fi

    if [ "$ETH_IFACE" = "auto" ] || ! ip link show "$ETH_IFACE" &> /dev/null; then
        local detected_eth
        detected_eth=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
        if [ -n "$detected_eth" ] && [ "$detected_eth" != "$WIFI_IFACE" ]; then
            if [ "$ETH_IFACE" != "auto" ]; then
                log_warn "Interface $ETH_IFACE không tồn tại, tự động chuyển sang interface mặc định: $detected_eth"
            else
                log_info "Tự động phát hiện Outbound/Ethernet interface: $detected_eth"
            fi
            ETH_IFACE="$detected_eth"
        fi
    fi
}

# Kiểm tra interface có tồn tại
check_interface() {
    local iface=$1
    if ! ip link show "$iface" &> /dev/null; then
        log_error "Interface $iface không tồn tại!"
        log_info "Danh sách interface hiện có:"
        ip link show | grep -E "^[0-9]+" | awk '{print "  - " $2}' | sed 's/:$//'
        return 1
    fi
    return 0
}

# Kiểm tra và cài đặt packages cần thiết
check_dependencies() {
    log_info "Kiểm tra các công cụ cần thiết..."
    local missing_cmds=()

    for cmd in hostapd dnsmasq iptables ip iw; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        log_warn "Thiếu các công cụ: ${missing_cmds[*]}"
        if [ "$NON_INTERACTIVE" = "1" ]; then
            log_info "Đang tự động cài đặt các package thiếu..."
            apt-get update && apt-get install -y hostapd dnsmasq iptables iproute2 iw wireless-tools wireless-regdb
        else
            read -p "Bạn có muốn cài đặt không? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                apt-get update
                apt-get install -y hostapd dnsmasq iptables iproute2 iw wireless-tools wireless-regdb
            else
                log_error "Không thể tiếp tục mà thiếu các package cần thiết!"
                exit 1
            fi
        fi
    fi
}

# Hiển thị thông tin WiFi adapter
show_adapter_info() {
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Thông tin WiFi Adapter: $WIFI_IFACE"
    log_info "═══════════════════════════════════════════════════════════"

    local driver=""
    if [ -L "/sys/class/net/$WIFI_IFACE/device/driver" ]; then
        driver=$(basename "$(readlink /sys/class/net/$WIFI_IFACE/device/driver)" 2>/dev/null)
    fi
    log_info "Driver: ${driver:-Unknown}"

    local phy
    phy=$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/wiphy/ {print "phy"$2}')
    log_info "Physical device: ${phy:-Unknown}"

    # Kiểm tra AP mode support
    if iw phy "$phy" info 2>/dev/null | grep -A 10 "Supported interface modes" | grep -q "AP"; then
        log_info "✓ Hỗ trợ AP mode"
    else
        log_error "✗ KHÔNG hỗ trợ AP mode!"
        log_error "Adapter này không thể làm Access Point!"
        return 1
    fi

    # Hiển thị regulatory domain
    local reg_domain
    reg_domain=$(iw reg get | grep country | head -1 | awk '{print $2}' | tr -d ':')
    log_info "Regulatory Domain: ${reg_domain:-Not set}"

    # Hiển thị các band được hỗ trợ
    log_info "Các band được hỗ trợ:"
    if iw phy "$phy" info 2>/dev/null | grep -q "Band 1:"; then
        log_info "  ✓ 2.4 GHz (Band 1)"
    fi
    if iw phy "$phy" info 2>/dev/null | grep -q "Band 2:"; then
        log_info "  ✓ 5 GHz (Band 2)"
    fi

    log_info "═══════════════════════════════════════════════════════════"
    echo ""
}

# Phát hiện các kênh khả dụng cho AP mode
detect_available_channels() {
    # Nếu người dùng đã chỉ định kênh cố định (không phải auto)
    if [ "$WIFI_CHANNEL" != "auto" ]; then
        if [ "$WIFI_BAND" = "5ghz" ] || [ "$WIFI_CHANNEL" -gt 14 ] 2>/dev/null; then
            WIFI_HW_MODE="a"
            WIFI_BAND="5ghz"
        else
            WIFI_HW_MODE="g"
            WIFI_BAND="2.4ghz"
        fi
        log_info "Sử dụng kênh cấu hình sẵn: Band $WIFI_BAND, Channel $WIFI_CHANNEL (hw_mode=$WIFI_HW_MODE)"
        return 0
    fi

    log_info "Đang phát hiện các kênh khả dụng cho AP mode..."

    local available_24ghz=()
    local available_5ghz=()
    local phy
    phy=$(iw dev "$WIFI_IFACE" info | awk '/wiphy/ {print "phy"$2}')

    # Scan 2.4GHz channels (1-14)
    for chan in {1..14}; do
        if iw phy "$phy" info 2>/dev/null | grep -A 50 "Band 1:" | grep "MHz \[${chan}\]" | grep -vE "disabled|no IR|NO-IR|radar" > /dev/null; then
            available_24ghz+=("$chan")
        fi
    done

    # Scan 5GHz channels
    for chan in 36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165; do
        if iw phy "$phy" info 2>/dev/null | grep -A 200 "Band 2:" | grep "MHz \[${chan}\]" | grep -vE "disabled|no IR|NO-IR|radar" > /dev/null; then
            available_5ghz+=("$chan")
        fi
    done

    log_info "Kênh 2.4GHz khả dụng: ${available_24ghz[*]:-None}"
    log_info "Kênh 5GHz khả dụng: ${available_5ghz[*]:-None}"

    # Nếu chỉ định WIFI_BAND=2.4ghz thì ưu tiên 2.4GHz
    if [ "$WIFI_BAND" = "2.4ghz" ] && [ ${#available_24ghz[@]} -gt 0 ]; then
        for preferred in 6 1 11; do
            if [[ " ${available_24ghz[*]} " =~ " ${preferred} " ]]; then
                WIFI_CHANNEL=$preferred
                break
            fi
        done
        if [ "$WIFI_CHANNEL" = "auto" ]; then
            WIFI_CHANNEL="${available_24ghz[0]}"
        fi
        WIFI_HW_MODE="g"
        log_info "→ Chọn kênh 2.4GHz: $WIFI_CHANNEL"
        return 0
    fi

    # Mặc định ưu tiên 5GHz nếu có, nếu không thì 2.4GHz
    if [ "$WIFI_BAND" != "2.4ghz" ] && [ ${#available_5ghz[@]} -gt 0 ]; then
        WIFI_CHANNEL="${available_5ghz[0]}"
        WIFI_HW_MODE="a"
        WIFI_BAND="5ghz"
        log_info "→ Chọn kênh 5GHz: $WIFI_CHANNEL"
    elif [ ${#available_24ghz[@]} -gt 0 ]; then
        for preferred in 6 1 11; do
            if [[ " ${available_24ghz[*]} " =~ " ${preferred} " ]]; then
                WIFI_CHANNEL=$preferred
                break
            fi
        done
        if [ "$WIFI_CHANNEL" = "auto" ]; then
            WIFI_CHANNEL="${available_24ghz[0]}"
        fi
        WIFI_HW_MODE="g"
        WIFI_BAND="2.4ghz"
        log_info "→ Chọn kênh 2.4GHz: $WIFI_CHANNEL"
    else
        log_error "Không tìm thấy kênh nào khả dụng cho AP mode!"
        return 1
    fi

    return 0
}

# Thiết lập regulatory domain
set_regulatory_domain() {
    local country=$1
    log_info "Thiết lập regulatory domain: $country"

    iw reg set "$country" 2>/dev/null
    sleep 1

    local current
    current=$(iw reg get | grep country | head -1 | awk '{print $2}' | tr -d ':')
    if [ "$current" = "$country" ]; then
        log_info "✓ Regulatory domain đã được đặt: $country"
        return 0
    else
        log_warn "Không thể thay đổi regulatory domain (hiện tại: ${current:-unknown})"
        return 1
    fi
}

# Debug: Hiển thị các frequency/channel hỗ trợ chi tiết
debug_show_frequencies() {
    log_debug "═══════════════════════════════════════════════════════════"
    log_debug "Chi tiết Frequencies/Channels"
    log_debug "═══════════════════════════════════════════════════════════"

    local phy
    phy=$(iw dev "$WIFI_IFACE" info | awk '/wiphy/ {print "phy"$2}')

    echo ""
    log_debug "2.4 GHz Band:"
    iw phy "$phy" info 2>/dev/null | grep -A 50 "Band 1:" | grep "MHz" | head -14

    echo ""
    log_debug "5 GHz Band:"
    iw phy "$phy" info 2>/dev/null | grep -A 200 "Band 2:" | grep "MHz" | head -30

    log_debug "═══════════════════════════════════════════════════════════"
    echo ""
}

# Menu để user chọn channel thủ công
interactive_channel_selection() {
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Chọn band và channel thủ công"
    log_info "═══════════════════════════════════════════════════════════"

    echo ""
    echo "Chọn WiFi Band:"
    echo "  1) 2.4 GHz (Tương thích hơn, tầm xa hơn)"
    echo "  2) 5 GHz (Nhanh hơn, ít can nhiễu)"
    echo "  3) Hiển thị debug info"
    echo "  4) Thử thay đổi Country Code"
    echo ""
    read -p "Lựa chọn (1-4): " band_choice

    case $band_choice in
        1)
            WIFI_HW_MODE="g"
            WIFI_BAND="2.4ghz"
            echo ""
            echo "Kênh phổ biến cho 2.4GHz: 1, 6, 11"
            read -p "Nhập số channel (1-14, đề xuất: 6): " WIFI_CHANNEL
            WIFI_CHANNEL=${WIFI_CHANNEL:-6}
            ;;
        2)
            WIFI_HW_MODE="a"
            WIFI_BAND="5ghz"
            echo ""
            echo "Kênh phổ biến cho 5GHz: 36, 40, 44, 48, 149, 153, 157, 161, 165"
            read -p "Nhập số channel (đề xuất: 149): " WIFI_CHANNEL
            WIFI_CHANNEL=${WIFI_CHANNEL:-149}
            ;;
        3)
            debug_show_frequencies
            interactive_channel_selection
            return
            ;;
        4)
            read -p "Nhập country code (mặc định: US): " new_country
            new_country=${new_country:-US}
            set_regulatory_domain "$new_country"
            COUNTRY_CODE="$new_country"
            WIFI_CHANNEL="auto"
            if ! detect_available_channels; then
                interactive_channel_selection
            fi
            return
            ;;
        *)
            log_error "Lựa chọn không hợp lệ"
            interactive_channel_selection
            return
            ;;
    esac

    log_info "→ Đã chọn: Band $WIFI_BAND, Channel $WIFI_CHANNEL, Mode $WIFI_HW_MODE"
}

# Xóa các rule iptables của riêng AP (An toàn cho Docker trên host)
cleanup_iptables() {
    if [ -n "$WIFI_IFACE" ] && [ -n "$ETH_IFACE" ]; then
        iptables -D FORWARD -i "$WIFI_IFACE" -o "$ETH_IFACE" -j ACCEPT 2>/dev/null
        iptables -D FORWARD -i "$ETH_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
        iptables -t nat -D POSTROUTING -s "$AP_SUBNET" -o "$ETH_IFACE" -j MASQUERADE 2>/dev/null
        iptables -D INPUT -i "$WIFI_IFACE" -j ACCEPT 2>/dev/null
    fi
}

# Dừng các service cũ
stop_services() {
    log_info "Dừng các tiến trình AP cũ (nếu có)..."

    # Dừng hostapd theo PID file
    if [ -f "$HOSTAPD_PID" ]; then
        local pid
        pid=$(cat "$HOSTAPD_PID")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$HOSTAPD_PID"
    fi

    pkill -f "$HOSTAPD_CONF" 2>/dev/null

    # Dừng dnsmasq theo PID file
    if [ -f "$DNSMASQ_PID" ]; then
        local pid
        pid=$(cat "$DNSMASQ_PID")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$DNSMASQ_PID"
    fi

    pkill -f "$DNSMASQ_CONF" 2>/dev/null

    # Gỡ các rule iptables của AP
    cleanup_iptables

    # Đảm bảo interface clean
    if ip link show "$WIFI_IFACE" &> /dev/null; then
        ip addr flush dev "$WIFI_IFACE" 2>/dev/null
        ip link set "$WIFI_IFACE" down 2>/dev/null
        sleep 1
    fi
}

# Cấu hình network interface
setup_network() {
    log_info "Cấu hình network interface $WIFI_IFACE..."

    # Unblock rfkill nếu có
    if command -v rfkill &> /dev/null; then
        rfkill unblock wifi 2>/dev/null || true
    fi

    # Đảm bảo interface ở chế độ managed/AP sạch trước khi chạy
    ip link set "$WIFI_IFACE" down 2>/dev/null
    ip addr flush dev "$WIFI_IFACE" 2>/dev/null
    sleep 1

    # Up interface và gán IP
    ip link set "$WIFI_IFACE" up
    sleep 1
    if ip addr add "${AP_IP}/24" dev "$WIFI_IFACE"; then
        log_info "✓ Đã gán IP $AP_IP cho $WIFI_IFACE"
    else
        log_error "Không thể gán IP cho $WIFI_IFACE"
        return 1
    fi
}

# Cấu hình IP forwarding và routing
setup_routing() {
    log_info "Cấu hình IP forwarding và routing..."

    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1 || log_warn "Không thể ghi sysctl ip_forward (có thể đã được bật ở host)"
    sysctl -w net.ipv4.conf."$WIFI_IFACE".proxy_arp=1 > /dev/null 2>&1 || true
    if ip link show "$ETH_IFACE" &> /dev/null; then
        sysctl -w net.ipv4.conf."$ETH_IFACE".proxy_arp=1 > /dev/null 2>&1 || true
    fi
    sysctl -w net.ipv4.conf.all.proxy_arp=1 > /dev/null 2>&1 || true

    log_info "✓ IP forwarding đã được cấu hình"
}

# Cấu hình iptables (Không dùng iptables -F để tránh xóa chain của Docker)
setup_iptables() {
    log_info "Cấu hình iptables cho AP ($WIFI_IFACE <-> $ETH_IFACE)..."

    cleanup_iptables

    iptables -I FORWARD 1 -i "$WIFI_IFACE" -o "$ETH_IFACE" -j ACCEPT
    iptables -I FORWARD 1 -i "$ETH_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -A POSTROUTING -s "$AP_SUBNET" -o "$ETH_IFACE" -j MASQUERADE
    iptables -I INPUT 1 -i "$WIFI_IFACE" -j ACCEPT

    log_info "✓ iptables đã được cấu hình (an toàn cho Docker)"
}

# Tạo file cấu hình dnsmasq
create_dnsmasq_config() {
    log_info "Tạo cấu hình DHCP server (dnsmasq)..."

    mkdir -p "$(dirname "$DNSMASQ_LEASES")"

    cat > "$DNSMASQ_CONF" << EOF
interface=$WIFI_IFACE
except-interface=lo
listen-address=$AP_IP
bind-dynamic
dhcp-range=$DHCP_START,$DHCP_END,$DHCP_LEASE
dhcp-option=3,$AP_IP
dhcp-option=6,8.8.8.8,8.8.4.4
dhcp-leasefile=$DNSMASQ_LEASES
no-resolv
no-hosts
log-queries
log-dhcp
pid-file=$DNSMASQ_PID
EOF

    log_info "✓ File cấu hình dnsmasq: $DNSMASQ_CONF"
}

# Tạo file cấu hình hostapd
create_hostapd_config() {
    log_info "Tạo cấu hình Access Point (hostapd)..."

    cat > "$HOSTAPD_CONF" << EOF
interface=$WIFI_IFACE
driver=nl80211
ssid=$WIFI_SSID
hw_mode=$WIFI_HW_MODE
channel=$WIFI_CHANNEL
ignore_broadcast_ssid=$WIFI_HIDDEN

# Security - WPA2
wpa=2
wpa_passphrase=$WIFI_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP

# Country code
country_code=$COUNTRY_CODE

# Logging
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
EOF

    # Thêm cấu hình cho 802.11n/ac nếu là 5GHz
    if [ "$WIFI_HW_MODE" = "a" ]; then
        cat >> "$HOSTAPD_CONF" << EOF

# 802.11n/ac support (5GHz)
ieee80211n=1
ieee80211ac=1
wmm_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]
EOF
    else
        cat >> "$HOSTAPD_CONF" << EOF

# 802.11n support (2.4GHz)
ieee80211n=1
wmm_enabled=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]
EOF
    fi

    log_info "✓ File cấu hình hostapd: $HOSTAPD_CONF"
    log_debug "Config: hw_mode=$WIFI_HW_MODE, channel=$WIFI_CHANNEL, band=$WIFI_BAND"
}

# Khởi động dnsmasq
start_dnsmasq() {
    log_info "Khởi động DHCP server (dnsmasq)..."

    dnsmasq -C "$DNSMASQ_CONF"

    if [ $? -eq 0 ]; then
        sleep 1
        if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
            log_info "✓ dnsmasq đã khởi động (PID: $(cat "$DNSMASQ_PID"))"
            return 0
        fi
    fi

    log_error "Không thể khởi động dnsmasq"
    return 1
}

# Khởi động hostapd
start_hostapd() {
    log_info "Khởi động Access Point (hostapd)..."

    hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF"
    local ret=$?

    if [ $ret -eq 0 ]; then
        sleep 2
        if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
            log_info "✓ hostapd đã khởi động (PID: $(cat "$HOSTAPD_PID"))"
            return 0
        fi
    fi

    log_error "Không thể khởi động hostapd"
    log_warn "Đang thử chạy với debug mode để xem chi tiết lỗi..."
    echo ""
    log_debug "═══════════════════ HOSTAPD DEBUG OUTPUT ═══════════════════"
    timeout 5 hostapd -dd "$HOSTAPD_CONF" 2>&1 | tail -25
    log_debug "════════════════════════════════════════════════════════════"
    echo ""

    return 1
}

# Cleanup khi thoát
cleanup() {
    echo ""
    log_warn "Đang dừng Access Point và dọn dẹp tài nguyên..."
    stop_services
    log_info "Đã dọn dẹp xong!"
    exit 0
}

# Hiển thị trạng thái
show_status() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            WiFi Access Point - Trạng thái                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "📡 Interface: $WIFI_IFACE -> Outbound: $ETH_IFACE"
    echo "📡 SSID: $WIFI_SSID $([ "$WIFI_HIDDEN" = "1" ] && echo "(Ẩn)" || echo "(Hiện)")"
    echo "🔐 Password: $WIFI_PASSWORD"
    echo "📶 Band: $WIFI_BAND"
    echo "📻 Channel: $WIFI_CHANNEL (Mode: $WIFI_HW_MODE)"
    echo "🌐 Gateway: $AP_IP"
    echo "📋 DHCP Range: $DHCP_START - $DHCP_END"
    echo "🌍 Country Code: $COUNTRY_CODE"
    echo ""

    if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} hostapd đang chạy (PID: $(cat "$HOSTAPD_PID"))"
    else
        echo -e "${RED}✗${NC} hostapd không chạy"
    fi

    if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} dnsmasq đang chạy (PID: $(cat "$DNSMASQ_PID"))"
    else
        echo -e "${RED}✗${NC} dnsmasq không chạy"
    fi

    echo ""
    echo "Commands:"
    echo "  - Xem clients: cat $DNSMASQ_LEASES"
    echo "  - Dừng AP: Ctrl+C hoặc docker stop <container>"
    echo ""
}

#===============================================================================
# Main
#===============================================================================

main() {
    trap cleanup SIGINT SIGTERM

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       WiFi Access Point Setup (Host & Docker Ready)        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    check_root
    check_dependencies
    resolve_interfaces

    log_info "Kiểm tra network interfaces..."
    if ! check_interface "$WIFI_IFACE"; then
        exit 1
    fi
    if ! check_interface "$ETH_IFACE"; then
        log_warn "Interface Ethernet $ETH_IFACE không tồn tại"
        log_warn "NAT sẽ không hoạt động nếu không có kết nối internet"
    fi

    echo ""
    show_adapter_info || exit 1

    # Set regulatory domain
    set_regulatory_domain "$COUNTRY_CODE"

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Phát hiện kênh tự động"
    log_info "═══════════════════════════════════════════════════════════"

    if ! detect_available_channels; then
        log_warn "Không thể tự động phát hiện kênh!"
        if [ "$NON_INTERACTIVE" = "1" ]; then
            log_warn "Chế độ NON_INTERACTIVE: fallback về 2.4GHz Channel 6"
            WIFI_BAND="2.4ghz"
            WIFI_HW_MODE="g"
            WIFI_CHANNEL="6"
        else
            echo ""
            read -p "Bạn có muốn chọn thủ công không? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                interactive_channel_selection
            else
                log_error "Không thể tiếp tục mà không có kênh hợp lệ!"
                exit 1
            fi
        fi
    fi

    # Confirm settings
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Cấu hình cuối cùng:"
    log_info "  - WiFi Interface: $WIFI_IFACE"
    log_info "  - Outbound Interface: $ETH_IFACE"
    log_info "  - Band: $WIFI_BAND"
    log_info "  - Channel: $WIFI_CHANNEL"
    log_info "  - HW Mode: $WIFI_HW_MODE"
    log_info "  - Country: $COUNTRY_CODE"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""

    if [ "$NON_INTERACTIVE" != "1" ]; then
        read -p "Tiếp tục với cấu hình này? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Hủy bỏ..."
            exit 0
        fi
    fi

    stop_services
    setup_network || exit 1
    setup_routing || exit 1
    setup_iptables || exit 1
    create_dnsmasq_config || exit 1
    create_hostapd_config || exit 1
    start_dnsmasq || exit 1

    if ! start_hostapd; then
        log_error "════════════════════════════════════════════════════════════"
        log_error "KHÔNG THỂ KHỞI ĐỘNG HOSTAPD!"
        log_error "════════════════════════════════════════════════════════════"
        cleanup
        exit 1
    fi

    show_status

    log_info "Access Point đang chạy... (Nhấn Ctrl+C hoặc docker stop để dừng)"
    while true; do
        sleep 5 &
        wait $!
        if [ -f "$HOSTAPD_PID" ]; then
            if ! kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
                log_error "hostapd đã bị dừng bất ngờ!"
                cleanup
            fi
        fi
        if [ -f "$DNSMASQ_PID" ]; then
            if ! kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
                log_error "dnsmasq đã bị dừng bất ngờ!"
                cleanup
            fi
        fi
    done
}

main "$@"
