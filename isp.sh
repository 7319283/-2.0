#!/bin/bash
# =============================================================
#  ISP — Настройка маршрутизатора провайдера
#  ОС: Альт JeOS (Alt Linux)
#  Модуль 1, КОД 09.02.06-1-2026
#
#  Интерфейсы (уточните через: ip link show):
#    ens18 / eth0  — в сторону Internet (DHCP)
#    ens19 / eth1  — в сторону HQ-RTR  (172.16.1.0/28)
#    ens20 / eth2  — в сторону BR-RTR  (172.16.2.0/28)
#
#  ПЕРЕД ЗАПУСКОМ: проверьте имена интерфейсов и поправьте
#  переменные ниже!
# =============================================================

# ---------- ПЕРЕМЕННЫЕ — ПРОВЕРЬТЕ И ПОМЕНЯЙТЕ ----------
WAN_IF="ens18"        # интерфейс в сторону Internet (DHCP)
HQ_IF="ens19"         # интерфейс в сторону HQ-RTR
BR_IF="ens20"         # интерфейс в сторону BR-RTR

HQ_NET="172.16.1.0/28"
HQ_GW="172.16.1.1"    # IP ISP на линке к HQ-RTR

BR_NET="172.16.2.0/28"
BR_GW="172.16.2.1"    # IP ISP на линке к BR-RTR

TIMEZONE="Europe/Moscow"   # <<<< поменяйте под место проведения
# --------------------------------------------------------

LOG="/root/isp_setup.log"
exec > >(tee -a "$LOG") 2>&1
echo "========================================"
echo " ISP setup started: $(date)"
echo "========================================"

# ---------- 1. ПРОВЕРКА ИНТЕРФЕЙСОВ ----------
echo "[1] Проверка интерфейсов..."
for IF in "$WAN_IF" "$HQ_IF" "$BR_IF"; do
    if ! ip link show "$IF" &>/dev/null; then
        echo "  [WARN] Интерфейс $IF не найден! Доступные:"
        ip link show | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':'
        echo "  Поправьте переменные в начале скрипта и перезапустите."
    else
        echo "  [OK] $IF найден"
    fi
done

# ---------- 2. HOSTNAME ----------
echo "[2] Установка hostname..."
hostnamectl set-hostname isp.au-team.irpo 2>/dev/null || \
    echo "isp.au-team.irpo" > /etc/hostname

grep -q "isp.au-team.irpo" /etc/hosts || \
    echo "127.0.1.1  isp.au-team.irpo isp" >> /etc/hosts
echo "  [OK] hostname = isp.au-team.irpo"

# ---------- 3. TIMEZONE ----------
echo "[3] Часовой пояс: $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || \
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "  [OK]"

# ---------- 4. СЕТЕВЫЕ ИНТЕРФЕЙСЫ ----------
echo "[4] Настройка сети через NetworkManager / ifupdown..."

# Определяем что используется
if systemctl is-active NetworkManager &>/dev/null; then
    echo "  Используется NetworkManager"

    # WAN — DHCP
    nmcli con show "$WAN_IF" &>/dev/null && nmcli con delete "$WAN_IF" 2>/dev/null
    nmcli con add type ethernet con-name "$WAN_IF" ifname "$WAN_IF" \
        ipv4.method auto \
        connection.autoconnect yes
    nmcli con up "$WAN_IF"
    echo "  [OK] $WAN_IF = DHCP"

    # HQ link
    nmcli con show "${HQ_IF}" &>/dev/null && nmcli con delete "${HQ_IF}" 2>/dev/null
    nmcli con add type ethernet con-name "${HQ_IF}" ifname "$HQ_IF" \
        ipv4.method manual \
        ipv4.addresses "${HQ_GW}/28" \
        connection.autoconnect yes
    nmcli con up "${HQ_IF}"
    echo "  [OK] $HQ_IF = $HQ_GW/28"

    # BR link
    nmcli con show "${BR_IF}" &>/dev/null && nmcli con delete "${BR_IF}" 2>/dev/null
    nmcli con add type ethernet con-name "${BR_IF}" ifname "$BR_IF" \
        ipv4.method manual \
        ipv4.addresses "${BR_GW}/28" \
        connection.autoconnect yes
    nmcli con up "${BR_IF}"
    echo "  [OK] $BR_IF = $BR_GW/28"

else
    echo "  Используется ifupdown/etcnet"
    # Для Alt Linux с etcnet (классика)
    NETDIR="/etc/net/ifaces"

    mkdir -p "$NETDIR/$WAN_IF"
    cat > "$NETDIR/$WAN_IF/options" <<EOF
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=eth
EOF

    mkdir -p "$NETDIR/$HQ_IF"
    cat > "$NETDIR/$HQ_IF/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
EOF
    echo "${HQ_GW}/28" > "$NETDIR/$HQ_IF/ipv4address"

    mkdir -p "$NETDIR/$BR_IF"
    cat > "$NETDIR/$BR_IF/options" <<EOF
BOOTPROTO=static
ONBOOT=yes
TYPE=eth
EOF
    echo "${BR_GW}/28" > "$NETDIR/$BR_IF/ipv4address"

    service network restart 2>/dev/null || systemctl restart network 2>/dev/null
    echo "  [OK] Конфиги etcnet применены"
fi

# ---------- 5. IP FORWARDING ----------
echo "[5] Включение IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

grep -q "net.ipv4.ip_forward" /etc/sysctl.conf && \
    sed -i 's/.*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

echo "  [OK]"

# ---------- 6. NAT (MASQUERADE) для HQ и BR ----------
echo "[6] Настройка NAT (MASQUERADE)..."

# Ставим iptables если нет
if ! command -v iptables &>/dev/null; then
    apt-get install -y iptables 2>/dev/null || true
fi

# Сбрасываем старые правила MASQUERADE для наших сетей
iptables -t nat -D POSTROUTING -s "$HQ_NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -s "$BR_NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null

# Добавляем
iptables -t nat -A POSTROUTING -s "$HQ_NET" -o "$WAN_IF" -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$BR_NET" -o "$WAN_IF" -j MASQUERADE

# Разрешаем FORWARD
iptables -C FORWARD -i "$HQ_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$HQ_IF" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -i "$BR_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$BR_IF" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "  [OK] NAT настроен"

# Сохраняем iptables
if command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true

    # Для Alt Linux
    if [ -f /etc/sysconfig/iptables ]; then
        echo "  [OK] Правила сохранены в /etc/sysconfig/iptables"
    fi
fi

# Включаем iptables в автозагрузку (Alt Linux)
systemctl enable iptables 2>/dev/null || true

# ---------- 7. МАРШРУТ ПО УМОЛЧАНИЮ ----------
echo "[7] Проверка маршрута по умолчанию..."
sleep 3  # ждём DHCP
ip route show default
if ! ip route show default | grep -q default; then
    echo "  [WARN] Маршрут по умолчанию не получен по DHCP — проверьте $WAN_IF"
else
    echo "  [OK]"
fi

# ---------- 8. NGINX как reverse proxy (для задания 9 модуля 2) ----------
# Здесь только установка, конфиг делается в модуле 2
echo "[8] Установка nginx (для будущего reverse proxy)..."
if ! command -v nginx &>/dev/null; then
    apt-get install -y nginx 2>/dev/null && echo "  [OK] nginx установлен" || \
        echo "  [SKIP] nginx не удалось установить (сделайте вручную)"
else
    echo "  [OK] nginx уже установлен"
fi

# ---------- ИТОГ ----------
echo ""
echo "========================================"
echo " ISP setup DONE: $(date)"
echo "========================================"
echo ""
echo " Проверьте:"
echo "   ip addr show"
echo "   ip route show"
echo "   ping 8.8.8.8"
echo ""
echo " Лог: $LOG"
