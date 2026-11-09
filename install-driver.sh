#!/bin/bash

#===============================================================================
# Script: Setup Host & Install RTL8821AU (TP-Link 2357:011f) Driver for Linux
# Description: Tự động cài đặt driver USB WiFi (8821au DKMS) và cấu hình Host
#              để sẵn sàng chạy container wifi-ap trên máy Linux mới.
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRIVER_REPO="https://github.com/morrownr/8821au-20210708.git"
DRIVER_DIR="/usr/src/rtl8821au-git"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Vui lòng chạy script này với quyền root!"
        echo "Sử dụng: sudo $0"
        exit 1
    fi
}

# 1. Cấu hình NetworkManager (nếu có trên Host) bỏ qua USB WiFi wlx*
configure_network_manager() {
    if [ -d "/etc/NetworkManager" ]; then
        log_info "Phát hiện NetworkManager trên Host, cấu hình bỏ qua các thiết bị USB WiFi (wlx*)..."
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/99-unmanaged-usb-wifi.conf << 'EOF'
[keyfile]
unmanaged-devices=interface-name:wlx*
EOF
        if command -v systemctl &> /dev/null && systemctl is-active --quiet NetworkManager; then
            systemctl reload NetworkManager || true
        fi
        log_info "✓ Đã cấu hình NetworkManager không chiếm quyền USB WiFi"
    fi
}

# 2. Cài đặt các gói phụ thuộc và linux-headers phù hợp với kernel hiện tại
install_dependencies() {
    log_info "Cập nhật apt và cài đặt các công cụ build (dkms, git, build-essential)..."
    apt-get update
    apt-get install -y dkms git build-essential bc libelf-dev usbutils iw rfkill

    local kver
    kver=$(uname -r)
    log_info "Đang cài đặt linux-headers cho kernel: $kver"

    if apt-cache show "linux-headers-$kver" &> /dev/null; then
        apt-get install -y "linux-headers-$kver"
    else
        log_warn "Không tìm thấy gói chính xác linux-headers-$kver, thử cài meta-package theo kiến trúc..."
        local arch
        arch=$(dpkg --print-architecture)
        apt-get install -y "linux-headers-$arch" || apt-get install -y linux-headers-generic
    fi

    if [ ! -d "/lib/modules/$kver/build" ]; then
        log_error "Thư mục /lib/modules/$kver/build chưa tồn tại!"
        log_warn "Nếu bạn vừa nâng cấp kernel thông qua apt, hãy khởi động lại máy (reboot) rồi chạy lại script này."
        exit 1
    fi
}

# 3. Kiểm tra và cài đặt driver 8821au qua DKMS
install_8821au_driver() {
    local kver
    kver=$(uname -r)

    if /usr/sbin/modinfo 8821au &> /dev/null; then
        log_info "✓ Driver module 8821au đã được cài đặt sẵn cho kernel $kver!"
        /usr/sbin/modprobe 8821au || true
        return 0
    fi

    log_info "Tải mã nguồn driver RTL8821AU (morrownr/8821au-20210708)..."
    rm -rf "$DRIVER_DIR"
    git clone --depth 1 "$DRIVER_REPO" "$DRIVER_DIR"

    cd "$DRIVER_DIR"
    log_info "Đang biên dịch và cài đặt driver qua DKMS (có thể mất 1-3 phút)..."

    if [ -f "./install-driver.sh" ]; then
        # Chạy ở chế độ NoPrompt để không hỏi reboot cuối script
        ./install-driver.sh NoPrompt
    else
        dkms add .
        local drv_ver
        drv_ver=$(awk -F'"' '/PACKAGE_VERSION/{print $2}' dkms.conf)
        dkms build -m rtl8821au -v "$drv_ver"
        dkms install -m rtl8821au -v "$drv_ver"
    fi

    log_info "Đang nạp module 8821au vào kernel..."
    /usr/sbin/depmod -a
    /usr/sbin/modprobe 8821au
    log_info "✓ Đã cài đặt và nạp thành công module 8821au!"
}

# 4. Kiểm tra trạng thái thiết bị sau khi cài
verify_device() {
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Kiểm tra nhận diện USB WiFi Dongle"
    log_info "═══════════════════════════════════════════════════════════"

    if lsusb | grep -qiE "2357:011f|Realtek|802\.11ac|WLAN"; then
        log_info "✓ Đã phát hiện USB WiFi trên cổng USB:"
        lsusb | grep -iE "2357:011f|Realtek|802\.11ac|WLAN" | sed 's/^/  /'
    else
        log_warn "Chưa thấy USB WiFi cắm vào máy (hoặc chưa passthrough USB vào VM)."
    fi

    sleep 2
    local wifi_iface
    wifi_iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | grep '^wlx' | head -1)
    if [ -z "$wifi_iface" ]; then
        wifi_iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)
    fi

    if [ -n "$wifi_iface" ]; then
        log_info "✓ Interface WiFi đã sẵn sàng: $wifi_iface"
    else
        log_warn "Chưa thấy network interface wlx* (hãy cắm USB WiFi dongle vào để kiểm tra)."
    fi

    echo ""
    log_info "Hoàn tất! Giờ bạn có thể khởi chạy Access Point bằng lệnh:"
    echo "  docker compose up -d --build"
    echo ""
}

main() {
    check_root
    configure_network_manager
    install_dependencies
    install_8821au_driver
    verify_device
}

main "$@"

