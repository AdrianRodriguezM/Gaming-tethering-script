#!/bin/bash
# =============================================
#  Gaming Tethering Script 
#  Author: Adrian RM
#  Includes:
#   - USB autosuspend fix
#   - TCP keepalive tuning
#   - fq_codel + BBR
#   - Power tuning + CPU performance
#   - Chrome/Edge realtime priority
#   - Keepalive + Heartbeat + Watchdog with logging
# =============================================

IFACE=$(ip -o addr show | awk '/inet / && ($4 ~ /^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\./) {print $2; exit}')
DNS_FILE="/etc/resolv.conf"
EDGE_BIN=$(command -v microsoft-edge 2>/dev/null)
CHROME_PID=$(pgrep -o chrome)
EDGE_PID=$(pgrep -o microsoft-edge)

KEEPALIVE_PID_FILE="/tmp/gaming_keepalive.pid"
WATCHDOG_PID_FILE="/tmp/gaming_watchdog.pid"
HEARTBEAT_PID_FILE="/tmp/gaming_heartbeat.pid"
WATCHDOG_LOG="/tmp/gaming_watchdog.log"

if [ -z "$IFACE" ]; then
    echo "[✖] No private network interface detected (tethering)."
    exit 1
fi

# -----------------------------
# TCP Keepalive (light refresh)
# -----------------------------
start_keepalive() {
    echo "[+] Starting TCP keepalive..."
    nohup bash -c "while true; do nc -z -w1 1.1.1.1 443 >/dev/null 2>&1; sleep 5; done" &
    echo $! > "$KEEPALIVE_PID_FILE"
}
stop_keepalive() {
    if [ -f "$KEEPALIVE_PID_FILE" ]; then
        kill "$(cat "$KEEPALIVE_PID_FILE")" 2>/dev/null
        rm -f "$KEEPALIVE_PID_FILE"
        echo "[✔] Keepalive stopped."
    fi
}

# -----------------------------
# UDP Heartbeat (anti-CGNAT)
# -----------------------------
start_heartbeat() {
    echo "[+] Starting UDP heartbeat..."
    nohup bash -c "while true; do echo -n > /dev/udp/1.1.1.1/443; sleep 3; done" &
    echo $! > "$HEARTBEAT_PID_FILE"
}
stop_heartbeat() {
    if [ -f "$HEARTBEAT_PID_FILE" ]; then
        kill "$(cat "$HEARTBEAT_PID_FILE")" 2>/dev/null
        rm -f "$HEARTBEAT_PID_FILE"
        echo "[✔] Heartbeat stopped."
    fi
}

# -----------------------------
# Watchdog (restarts interface if traffic loss detected)
# -----------------------------
start_watchdog() {
    echo "[+] Starting watchdog with logging..."
    echo "[LOG] === Watchdog start: $(date) ===" > "$WATCHDOG_LOG"
    nohup bash -c "
    TARGET='1.1.1.1'
    while true; do
        if ! ping -c1 -W3 \$TARGET >/dev/null 2>&1; then
            TS=\$(date '+%Y-%m-%d %H:%M:%S')
            echo \"[\$TS] ⚠ Connection loss detected, restarting $IFACE...\" >> $WATCHDOG_LOG
            sudo ip link set $IFACE down
            sleep 1
            sudo ip link set $IFACE up
            echo \"[\$TS] ✅ Interface $IFACE successfully restarted.\" >> $WATCHDOG_LOG
        fi
        sleep 2
    done
    " >/dev/null 2>&1 &
    echo $! > "$WATCHDOG_PID_FILE"
}
stop_watchdog() {
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        kill "$(cat "$WATCHDOG_PID_FILE")" 2>/dev/null
        rm -f "$WATCHDOG_PID_FILE"
        echo "[✔] Watchdog stopped. Log available at $WATCHDOG_LOG"
    fi
}

# -----------------------------
# Enable gaming mode
# -----------------------------
enable_gaming_mode() {
    echo "[⚙] Enabling Gaming Mode on $IFACE..."

    # --- Kernel tweaks ---
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
    sudo sysctl -w net.ipv4.tcp_ecn=0
    sudo sysctl -w net.core.netdev_max_backlog=2500
    sudo sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216'
    sudo sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216'
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1

    # --- TCP keepalive tuning ---
    sudo sysctl -w net.ipv4.tcp_keepalive_time=15
    sudo sysctl -w net.ipv4.tcp_keepalive_intvl=10
    sudo sysctl -w net.ipv4.tcp_keepalive_probes=3

    # --- Power tuning ---
    if command -v powertop &>/dev/null; then
        sudo powertop --auto-tune
    fi

    # --- CPU performance ---
    if command -v cpupower &>/dev/null; then
        sudo cpupower frequency-set -g performance
    fi

    # --- MTU and fq_codel ---
    sudo ip link set dev "$IFACE" mtu 1500
    sudo tc qdisc replace dev "$IFACE" root fq_codel target 5ms interval 100ms

    # --- DNS Cloudflare ---
    if [ -f "$DNS_FILE" ] && [ ! -f "${DNS_FILE}.bak_gaming" ]; then
        echo "[→] Creating DNS backup..."
        sudo cp "$DNS_FILE" "${DNS_FILE}.bak_gaming"
    fi
    echo "[→] Setting Cloudflare DNS (1.1.1.1 / 1.0.0.1)..."
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" | sudo tee "$DNS_FILE" >/dev/null

    # --- Unnecessary services ---
    sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
    sudo systemctl stop systemd-resolved 2>/dev/null

    # --- USB autosuspend ---
    echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend >/dev/null
    echo "options usbcore autosuspend=-1" | sudo tee /etc/modprobe.d/usb-autosuspend.conf >/dev/null
    for i in /sys/bus/usb/devices/*/power/control; do echo on | sudo tee $i >/dev/null; done

    # --- Browser priority ---
    PID_TARGET=${EDGE_PID:-$CHROME_PID}
    if [ -n "$PID_TARGET" ]; then
        echo "[+] Increasing browser priority (PID $PID_TARGET)..."
        sudo renice -n -20 -p "$PID_TARGET" >/dev/null
        sudo chrt -r -p 99 "$PID_TARGET" >/dev/null
        sudo taskset -cp 0,1 "$PID_TARGET" >/dev/null
    fi

    # --- Optimized Edge ---
    if [ -n "$EDGE_BIN" ]; then
        echo "[→] Launching optimized Microsoft Edge..."
        nohup "$EDGE_BIN" \
            --enable-features=WebRTCPipeWireCapturer \
            --disable-renderer-backgrounding \
            --disable-frame-rate-limit \
            --disable-background-timer-throttling \
            --no-proxy-server >/dev/null 2>&1 &
    fi

    # --- Launch helper processes ---
    start_keepalive
    start_heartbeat
    start_watchdog

    echo "[✔] Gaming Mode enabled on $IFACE."
    echo "[🕹] Keepalive + heartbeat + watchdog running with logging."
}

# -----------------------------
# Disable gaming mode
# -----------------------------
disable_gaming_mode() {
    echo "[⏹] Disabling Gaming Mode..."

    stop_keepalive
    stop_heartbeat
    stop_watchdog

    sudo tc qdisc del dev "$IFACE" root 2>/dev/null
    sudo ip link set dev "$IFACE" mtu 1500

    # --- Restore original DNS ---
    if [ -f "${DNS_FILE}.bak_gaming" ]; then
        sudo mv "${DNS_FILE}.bak_gaming" "$DNS_FILE"
        echo "[✔] DNS restored to original state."
    else
        echo "[!] No previous DNS backup found (possibly already restored or deleted)."
    fi

    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0

    if command -v cpupower &>/dev/null; then
        sudo cpupower frequency-set -g ondemand
    fi

    sudo systemctl start systemd-resolved 2>/dev/null
    sudo systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null

    echo "[✔] System restored. Watchdog logs: $WATCHDOG_LOG"
}

# -----------------------------
# Main control
# -----------------------------
case "$1" in
    on)  enable_gaming_mode ;;
    off) disable_gaming_mode ;;
    *)
        echo "Usage: sudo gaming.sh on|off"
        exit 1
        ;;
esac
