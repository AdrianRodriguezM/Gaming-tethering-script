#!/bin/bash
# =============================================
#  Gaming Thetering Script 
#  Autor: Adrian RM
#  Incluye:
#   - USB autosuspend fix
#   - TCP keepalive tuning
#   - fq_codel + BBR
#   - Power tuning + CPU performance
#   - Chrome/Edge prioridad realtime
#   - Keepalive + Heartbeat + Watchdog con logging
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
    echo "[✖] No se detectó interfaz de red privada (tethering)."
    exit 1
fi

# -----------------------------
# Keepalive TCP (refresco ligero)
# -----------------------------
start_keepalive() {
    echo "[+] Iniciando keepalive TCP..."
    nohup bash -c "while true; do nc -z -w1 1.1.1.1 443 >/dev/null 2>&1; sleep 5; done" &
    echo $! > "$KEEPALIVE_PID_FILE"
}
stop_keepalive() {
    if [ -f "$KEEPALIVE_PID_FILE" ]; then
        kill "$(cat "$KEEPALIVE_PID_FILE")" 2>/dev/null
        rm -f "$KEEPALIVE_PID_FILE"
        echo "[✔] Keepalive detenido."
    fi
}

# -----------------------------
# Heartbeat UDP (anti-CGNAT)
# -----------------------------
start_heartbeat() {
    echo "[+] Iniciando UDP heartbeat..."
    nohup bash -c "while true; do echo -n > /dev/udp/1.1.1.1/443; sleep 3; done" &
    echo $! > "$HEARTBEAT_PID_FILE"
}
stop_heartbeat() {
    if [ -f "$HEARTBEAT_PID_FILE" ]; then
        kill "$(cat "$HEARTBEAT_PID_FILE")" 2>/dev/null
        rm -f "$HEARTBEAT_PID_FILE"
        echo "[✔] Heartbeat detenido."
    fi
}

# -----------------------------
# Watchdog (reinicia interfaz si pierde tráfico)
# -----------------------------
start_watchdog() {
    echo "[+] Iniciando watchdog con logging..."
    echo "[LOG] === Inicio watchdog: $(date) ===" > "$WATCHDOG_LOG"
    nohup bash -c "
    TARGET='1.1.1.1'
    while true; do
        if ! ping -c1 -W3 \$TARGET >/dev/null 2>&1; then
            TS=\$(date '+%Y-%m-%d %H:%M:%S')
            echo \"[\$TS] ⚠ Pérdida detectada, reiniciando $IFACE...\" >> $WATCHDOG_LOG
            sudo ip link set $IFACE down
            sleep 1
            sudo ip link set $IFACE up
            echo \"[\$TS] ✅ Interfaz $IFACE reiniciada correctamente.\" >> $WATCHDOG_LOG
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
        echo "[✔] Watchdog detenido. Log disponible en $WATCHDOG_LOG"
    fi
}

# -----------------------------
# Activar modo gaming
# -----------------------------
enable_gaming_mode() {
    echo "[⚙] Activando Modo Gaming en $IFACE..."

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

    # --- MTU y fq_codel ---
    sudo ip link set dev "$IFACE" mtu 1500
    sudo tc qdisc replace dev "$IFACE" root fq_codel target 5ms interval 100ms

    # --- DNS Cloudflare ---
    if [ -f "$DNS_FILE" ] && [ ! -f "${DNS_FILE}.bak_gaming" ]; then
        echo "[→] Creando respaldo de DNS actual..."
        sudo cp "$DNS_FILE" "${DNS_FILE}.bak_gaming"
    fi
    echo "[→] Estableciendo DNS de Cloudflare (1.1.1.1 / 1.0.0.1)..."
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" | sudo tee "$DNS_FILE" >/dev/null

    # --- Servicios innecesarios ---
    sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
    sudo systemctl stop systemd-resolved 2>/dev/null

    # --- Autosuspend USB ---
    echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend >/dev/null
    echo "options usbcore autosuspend=-1" | sudo tee /etc/modprobe.d/usb-autosuspend.conf >/dev/null
    for i in /sys/bus/usb/devices/*/power/control; do echo on | sudo tee $i >/dev/null; done

    # --- Prioridad navegador ---
    PID_TARGET=${EDGE_PID:-$CHROME_PID}
    if [ -n "$PID_TARGET" ]; then
        echo "[+] Aumentando prioridad de navegador (PID $PID_TARGET)..."
        sudo renice -n -20 -p "$PID_TARGET" >/dev/null
        sudo chrt -r -p 99 "$PID_TARGET" >/dev/null
        sudo taskset -cp 0,1 "$PID_TARGET" >/dev/null
    fi

    # --- Edge optimizado ---
    if [ -n "$EDGE_BIN" ]; then
        echo "[→] Iniciando Microsoft Edge optimizado..."
        nohup "$EDGE_BIN" \
            --enable-features=WebRTCPipeWireCapturer \
            --disable-renderer-backgrounding \
            --disable-frame-rate-limit \
            --disable-background-timer-throttling \
            --no-proxy-server >/dev/null 2>&1 &
    fi

    # --- Lanzar procesos auxiliares ---
    start_keepalive
    start_heartbeat
    start_watchdog

    echo "[✔] Modo Gaming activado en $IFACE."
    echo "[🕹] Keepalive + heartbeat + watchdog activos con logging."
}

# -----------------------------
# Desactivar modo gaming
# -----------------------------
disable_gaming_mode() {
    echo "[⏹] Desactivando Modo Gaming ..."

    stop_keepalive
    stop_heartbeat
    stop_watchdog

    sudo tc qdisc del dev "$IFACE" root 2>/dev/null
    sudo ip link set dev "$IFACE" mtu 1500

    # --- Restaurar DNS original ---
    if [ -f "${DNS_FILE}.bak_gaming" ]; then
        sudo mv "${DNS_FILE}.bak_gaming" "$DNS_FILE"
        echo "[✔] DNS restaurado al estado original."
    else
        echo "[!] No se encontró respaldo de DNS previo. (posiblemente ya restaurado o eliminado)"
    fi

    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0

    if command -v cpupower &>/dev/null; then
        sudo cpupower frequency-set -g ondemand
    fi

    sudo systemctl start systemd-resolved 2>/dev/null
    sudo systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null

    echo "[✔] Sistema restaurado. Logs del watchdog: $WATCHDOG_LOG"
}

# -----------------------------
# Control principal
# -----------------------------
case "$1" in
    on)  enable_gaming_mode ;;
    off) disable_gaming_mode ;;
    *)
        echo "Uso: sudo gaming.sh on|off"
        exit 1
        ;;
esac
