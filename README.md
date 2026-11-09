# Docker WiFi Access Point (`wifi-ap`)

Giải pháp đóng gói **WiFi Access Point (`hostapd` + `dnsmasq` + `iptables` NAT)** trong Docker container trên Linux, hỗ trợ tự động nhận diện USB WiFi Dongle, tự động chọn băng tần/kênh tối ưu (5GHz / 2.4GHz) và không làm ảnh hưởng đến chuỗi mạng `iptables` của Docker trên máy Host.

---

## Tính năng nổi bật

- **Auto-detect Interfaces:** Tự động phát hiện USB WiFi interface (`wlx*` / `wlan*`) và cổng mạng Internet đầu ra (`ETH_IFACE`) khi để `auto`.
- **Auto-detect Band & Channel:** Tự động quét phần cứng (`iw phy`) để ưu tiên phát sóng **5GHz (802.11ac/n)** nếu card hỗ trợ, hoặc fallback về **2.4GHz (802.11n/g)** ở các kênh ít nhiễu (1, 6, 11).
- **Docker-safe `iptables`:** Chỉ thêm các rule NAT/FORWARD riêng của AP và tự động gỡ sạch khi `docker stop`, không dùng `iptables -F` gây mất mạng các container khác.
- **Không xung đột DNS Host:** Cấu hình `dnsmasq` chỉ lắng nghe trên IP của Access Point, không đụng cổng `53` với `systemd-resolved` trên Ubuntu/Debian.
- **Tự động khởi động lại:** Hỗ trợ `restart: unless-stopped` và health-check vòng lặp tự hồi phục khi rút/cắm lại USB WiFi hoặc khởi động lại máy.

---

## Bắt đầu nhanh (Quick Start)

### Bước 1: Cài đặt Driver USB WiFi trên máy Host (Chạy 1 lần cho máy mới)

Nếu bạn dùng USB WiFi chipset **Realtek RTL8821AU / RTL8811AU** (ví dụ: TP-Link Archer T2U Plus / Nano `2357:011f`), chạy script sau trên máy Host để tự động cài driver DKMS và cấu hình `NetworkManager` không tranh quyền của Docker:

```bash
chmod +x install-driver.sh
sudo ./install-driver.sh
```

*(Nếu `ip link` trên máy Host đã hiện sẵn interface `wlx...` hoặc `wlan...`, bạn có thể bỏ qua bước này).*

### Bước 2: Cấu hình thông tin WiFi (Tùy chọn)

Tạo file `.env` từ file mẫu `.env.example` để đặt tên WiFi (`WIFI_SSID`) và mật khẩu (`WIFI_PASSWORD`) riêng của bạn:

```bash
cp .env.example .env
nano .env
```

### Bước 3: Khởi chạy Access Point bằng Docker Compose

```bash
docker compose up -d --build
```

> **Lưu ý:** Nếu máy Host trước đó từng bị xóa chain NAT của bridge `docker0` khiến lúc `docker build` không phân giải được DNS, hãy build với `--network=host`:
> ```bash
> docker build --network=host -t wifi-ap-container:latest .
> docker compose up -d
> ```

---

## Các biến môi trường cấu hình (`.env`)

| Biến | Mặc định | Mô tả |
| :--- | :--- | :--- |
| `WIFI_IFACE` | `auto` | Tên card WiFi phát AP (`auto` sẽ tự động ưu tiên tìm USB WiFi `wlx*`) |
| `ETH_IFACE` | `auto` | Cổng mạng có Internet để NAT (`auto` tự tìm qua `default route`) |
| `WIFI_SSID` | `matinhieu` | Tên mạng WiFi phát ra |
| `WIFI_PASSWORD` | `88888888` | Mật khẩu WiFi (WPA2-PSK, tối thiểu 8 ký tự) |
| `WIFI_HIDDEN` | `0` | `0`: Hiện SSID, `1`: Ẩn SSID |
| `WIFI_BAND` | `auto` | `auto` (ưu tiên 5GHz), `5ghz`, hoặc `2.4ghz` |
| `WIFI_CHANNEL` | `auto` | `auto` hoặc chỉ định kênh cố định (VD: `6` cho 2.4GHz, `36`/`149` cho 5GHz) |
| `COUNTRY_CODE` | `US` | Mã quốc gia quy định tần số phát sóng (`US`, `VN`, `TW`, `JP`...) |
| `AP_IP` | `192.168.50.1` | Địa chỉ IP Gateway của Access Point |
| `AP_SUBNET` | `192.168.50.0/24` | Dải mạng con của Access Point |
| `DHCP_START` | `192.168.50.10` | IP bắt đầu cấp DHCP |
| `DHCP_END` | `192.168.50.100` | IP kết thúc cấp DHCP |
| `DHCP_LEASE` | `12h` | Thời gian thuê IP DHCP |

---

## Các lệnh kiểm tra & vận hành hữu ích

- **Xem log hoạt động của Access Point:**
  ```bash
  docker compose logs -f
  ```
- **Kiểm tra trạng thái phát sóng, kênh và công suất phát (`txpower`):**
  ```bash
  docker exec wifi-ap iw dev
  ```
- **Xem danh sách các thiết bị đang kết nối (IP, MAC, Hostname):**
  ```bash
  docker exec wifi-ap cat /var/lib/misc/dnsmasq.leases
  ```
- **Xem chi tiết cường độ tín hiệu (RSSI, tốc độ TX/RX) của từng thiết bị:**
  ```bash
  docker exec wifi-ap sh -c 'iw dev $(iw dev | awk "\$1==\"Interface\"{print \$2; exit}") station dump'
  ```
- **Dừng Access Point (tự động hạ card WiFi và gỡ rule `iptables`):**
  ```bash
  docker compose down
  ```

