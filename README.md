# Docker WiFi Access Point (`docker-wifi-ap`)

A plug-and-play **Dockerized WiFi Access Point (`hostapd` + `dnsmasq` + `iptables` NAT)** for Linux. It automatically detects USB WiFi dongles, selects optimal 5GHz/2.4GHz bands and channels, and manages NAT/routing rules without disrupting existing Docker `iptables` chains on the host.

---

## Key Features

- **Auto-detect Interfaces:** Automatically identifies your USB WiFi interface (`wlx*` / `wlan*`) and the outbound internet interface (`ETH_IFACE`) when set to `auto`.
- **Auto-detect Band & Channel:** Queries hardware capabilities (`iw phy`) to prioritize **5GHz (802.11ac/n)** when supported, or falls back to **2.4GHz (802.11n/g)** on non-overlapping channels (`1`, `6`, `11`).
- **Docker-safe `iptables`:** Inserts only AP-specific NAT/FORWARD rules and cleanly removes them on `docker stop`, avoiding `iptables -F` which would break other Docker containers.
- **No Host DNS Conflicts:** Configures `dnsmasq` to bind strictly to the AP gateway IP, avoiding port `53` conflicts with `systemd-resolved` on Ubuntu/Debian hosts.
- **Self-healing & Auto-restart:** Configured with `restart: unless-stopped` and a built-in process monitor to recover automatically across host reboots or USB dongle reconnects.

---

## Quick Start

### Step 1: Install the USB WiFi Driver on the Host (One-time setup)

If you are using a **Realtek RTL8821AU / RTL8811AU** USB WiFi adapter (e.g., TP-Link Archer T2U Plus / Nano `2357:011f`), run the included helper script on your Linux host to install the DKMS driver and configure `NetworkManager` to ignore `wlx*` interfaces:

```bash
chmod +x install-driver.sh
sudo ./install-driver.sh
```

*(If `ip link` on your host already shows your `wlx...` or `wlan...` interface, you can skip this step).*

### Step 2: Configure WiFi Credentials (Optional)

Create a `.env` file from `.env.example` to customize your `WIFI_SSID` and `WIFI_PASSWORD`:

```bash
cp .env.example .env
nano .env
```

### Step 3: Start the Access Point

```bash
docker compose up -d --build
```

> **Note:** If `docker build` fails to resolve DNS due to broken bridge NAT on the host, build the image using host networking first:
> ```bash
> docker build --network=host -t wifi-ap-container:latest .
> docker compose up -d
> ```

---

## Configuration (`.env`)

| Variable | Default | Description |
| :--- | :--- | :--- |
| `WIFI_IFACE` | `auto` | Wireless interface for the AP (`auto` prioritizes USB WiFi `wlx*` interfaces) |
| `ETH_IFACE` | `auto` | Outbound internet interface for NAT (`auto` detects via `default route`) |
| `WIFI_SSID` | `matinhieu` | WiFi network name (SSID) |
| `WIFI_PASSWORD` | `88888888` | WiFi WPA2-PSK passphrase (minimum 8 characters) |
| `WIFI_HIDDEN` | `0` | `0`: Broadcast SSID, `1`: Hide SSID |
| `WIFI_BAND` | `auto` | `auto` (prefers 5GHz), `5ghz`, or `2.4ghz` |
| `WIFI_CHANNEL` | `auto` | `auto` or a specific channel number (e.g., `6` for 2.4GHz, `36`/`149` for 5GHz) |
| `COUNTRY_CODE` | `US` | Regulatory domain country code (`US`, `VN`, `TW`, `JP`, etc.) |
| `AP_IP` | `192.168.50.1` | Access Point gateway IP address |
| `AP_SUBNET` | `192.168.50.0/24` | Access Point subnet CIDR |
| `DHCP_START` | `192.168.50.10` | DHCP pool start address |
| `DHCP_END` | `192.168.50.100` | DHCP pool end address |
| `DHCP_LEASE` | `12h` | DHCP lease duration |

---

## Useful Commands

- **View Access Point logs:**
  ```bash
  docker compose logs -f
  ```
- **Check wireless interface status, channel, and `txpower`:**
  ```bash
  docker exec wifi-ap iw dev
  ```
- **List connected DHCP clients (IP, MAC, Hostname):**
  ```bash
  docker exec wifi-ap cat /var/lib/misc/dnsmasq.leases
  ```
- **Inspect connected station signal strength (RSSI, TX/RX bitrates):**
  ```bash
  docker exec wifi-ap sh -c 'iw dev $(iw dev | awk "\$1==\"Interface\"{print \$2; exit}") station dump'
  ```
- **Stop the Access Point (automatically brings down the interface and cleans up `iptables` rules):**
  ```bash
  docker compose down
  ```

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
