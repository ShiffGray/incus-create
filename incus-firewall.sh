#!/bin/bash
#
# incus-firewall v2.0
# Автоматическая настройка UFW + br_netfilter + DHCP для Incus/IncusUI моста
#

DEFAULT_IFACE="incusbr0"
IFACE=""
V4_CIDR=""
V4_NET_CIDR=""
V6_CIDR=""
V4_GATEWAY=""
ACCESS_MODE="secure" # full = весь трафик, secure = изоляция + пробросы (по умолчанию), dns-only = только DNS (53) + DHCP (67) к gateway, tcp-udp = только TCP+UDP
DHCP_ENABLE="yes" # yes = включить DHCP на мосте, no = оставить как есть
SSH_PORTS=() # детектируемые порты SSH (из sshd_config), чтобы не потерять доступ после ufw enable
DEFAULT_PANEL_PORT="8443" # порт IncusUI по умолчанию
WAN_IFACE="" # WAN-интерфейс (default route) — нужен только для secure-режима

# ─── Запрос имени интерфейса ────────────────────────
ask_iface() {
    read -r -p "$MSG_ASK_IFACE" IFACE
    if [ -z "$IFACE" ]; then IFACE="$DEFAULT_IFACE"; fi
}

# ─── Запрос режима доступа ──────────────────────────
ask_access() {
    read -r -p "$MSG_ASK_ACCESS" ANSWER
    case "${ANSWER,,}" in
        f|full) ACCESS_MODE="full" ;;
        d|dns-only) ACCESS_MODE="dns-only" ;;
        p|ports|tcp-udp) ACCESS_MODE="tcp-udp" ;;
        *) ACCESS_MODE="secure" ;;
    esac
}

# ─── Запрос DHCP ─────────────────────────────────────
ask_dhcp() {
    read -r -p "$MSG_ASK_DHCP" ANSWER
    case "${ANSWER,,}" in
        n|no) DHCP_ENABLE="no" ;;
        *) DHCP_ENABLE="yes" ;;
    esac
}

# ─── Автоопределение подсетей интерфейса ────────────
# Хост-CIDR → сетевой-CIDR (10.223.29.1/24 → 10.223.29.0/24)
cidr_to_net() {
    local cidr="$1" ip prefix a b c d val mask net
    ip="${cidr%%/*}"
    prefix="${cidr##*/}"
    IFS=. read -r a b c d <<< "$ip"
    val=$(( (a<<24) | (b<<16) | (c<<8) | d ))
    if [ "$prefix" -eq 0 ]; then
        net=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
        net=$(( val & mask ))
    fi
    echo "$(( (net>>24)&255 )).$(( (net>>16)&255 )).$(( (net>>8)&255 )).$(( net&255 ))/$prefix"
}

detect_networks() {
    if ! ip link show "$IFACE" &>/dev/null; then
        log_error "$MSG_IFACE_NOT_FOUND" "$IFACE"
        exit 1
    fi

    # Первая IPv4 подсеть (с CIDR), исключая loopback 127.0.0.0/8
    V4_CIDR=$(ip -o addr show "$IFACE" | awk '/inet / && $4 !~ /^127\./ {print $4}' | head -1)
    if [ -z "$V4_CIDR" ]; then
        log_error "$MSG_NO_IPV4" "$IFACE"
        exit 1
    fi
    V4_NET_CIDR=$(cidr_to_net "$V4_CIDR")

    # Gateway IPv4 (обычно .1 в подсети)
    V4_NETWORK=$(echo "$V4_CIDR" | cut -d/ -f1)
    V4_GATEWAY=""
    for OCTET in 1 2 3 4; do
        V4_GATEWAY=$(echo "$V4_NETWORK" | awk -F. -v o="$OCTET" '{print $1"."$2"."$3"."o}')
        if ip route show | grep -q "$V4_GATEWAY"; then
            break
        fi
        V4_GATEWAY=""
    done
    if [ -z "$V4_GATEWAY" ]; then
        V4_GATEWAY="${V4_NETWORK%.*}.1"
    fi

    # Первая глобальная IPv6 подсеть (без link-local fe80::/10 и ::1/128)
    V6_CIDR=$(ip -o addr show "$IFACE" | awk '/inet6 / && !/fe80::/ && $4 !~ /^::1\// {print $4}' | head -1)
    if [ -z "$V6_CIDR" ]; then
        log_warning "$MSG_NO_IPV6" "$IFACE"
    fi
}

# ─── Автоопределение SSH порта ──────────────────────
# sshd может слушать несколько портов; drop-in'ы перекрывают основной конфиг.
# Нужно, чтобы после ufw enable не потерять SSH-доступ к серверу извне.
detect_ssh_port() {
    SSH_PORTS=()
    local conf port
    for conf in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$conf" ] || continue
        while read -r port; do
            [ -z "$port" ] && continue
            case " ${SSH_PORTS[*]} " in
                *" $port "*) ;;
                *) SSH_PORTS+=("$port") ;;
            esac
        done < <(sed -n 's/^[[:space:]]*Port[[:space:]]\+\([0-9][0-9]*\).*/\1/p' "$conf")
    done
    if [ "${#SSH_PORTS[@]}" -eq 0 ]; then
        SSH_PORTS=(22)
    fi
    log_info "$MSG_SSH_PORT" "${SSH_PORTS[*]}"
}

# ─── SSH порт ──────────────────────────────────────
# Смена SSH порта — в ssh-keys.sh. Здесь только открываем текущий порт в UFW,
# чтобы не потерять доступ к серверу после ufw enable.

# ─── Автоопределение WAN-интерфейса ────────────────
# Нужен только для secure-режима: пробросы разрешаются только с WAN,
# чтобы контейнеры не доставали друг друга (форвардинг контейнер→контейнер закрыт).
detect_wan() {
    WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -z "$WAN_IFACE" ]; then
        log_error "$MSG_WAN_NOT_FOUND"
        exit 1
    fi
    log_info "$MSG_WAN_IFACE" "$WAN_IFACE"
}

# ─── Установка зависимостей ────────────────────────
# Критичные базовые утилиты: без них скрипт бесполезен — проверяем в начале и ставим.
# incus здесь НЕ ставим — это задача инсталлятора (IncusUI.sh).
# Формат: команда:пакет
REQUIRED_CMDS=(
    "ufw:ufw"
    "ip:iproute2"
    "modprobe:kmod"
    "sysctl:procps"
)

install_deps() {
    local missing=() entry cmd pkg list="" still=""
    for entry in "${REQUIRED_CMDS[@]}"; do
        cmd="${entry%%:*}"
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$entry")
            list+=" ${entry##*:}"
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    log_warning "$MSG_DEPS_MISSING$list"
    read -r -p "$MSG_ASK_INSTALL_DEPS" ANSWER
    if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
        log_error "$MSG_DEPS_ABORT"
        exit 1
    fi

    apt-get update
    apt-get install -y $list

    for entry in "${missing[@]}"; do
        cmd="${entry%%:*}"
        if ! command -v "$cmd" &>/dev/null; then
            still+=" ${entry##*:}"
        fi
    done
    if [ -n "$still" ]; then
        log_error "$MSG_DEPS_STILL_MISSING$still"
        exit 1
    fi
    log_success "$MSG_DEPS_INSTALLED"
}

# ─── Настройка br_netfilter и DHCP ──────────────────
setup_kernel() {
    log_info "$MSG_BRNF_SETUP"

    # Загружаем модуль
    if ! lsmod | grep -q "^br_netfilter"; then
        modprobe br_netfilter 2>/dev/null || log_warning "$MSG_BRNF_MODPROBE_FAIL"
    fi

    # Автозагрузка при загрузке
    if ! grep -q "^br_netfilter$" /etc/modules-load.d/br_netfilter.conf 2>/dev/null; then
        mkdir -p /etc/modules-load.d
        echo "br_netfilter" | tee /etc/modules-load.d/br_netfilter.conf >/dev/null
        log_success "$MSG_BRNF_AUTOLOAD_ADDED"
    else
        log_success "$MSG_BRNF_AUTOLOAD_EXISTS"
    fi

    # Включаем bridge netfilter
    sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
    sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true
}

setup_dhcp() {
    if [ "$DHCP_ENABLE" != "yes" ]; then
        log_info "$MSG_DHCP_DISABLED"
        return
    fi

    log_info "$MSG_DHCP_ENABLING" "$IFACE"

    # IPv4 DHCP
    if incus network set "$IFACE" ipv4.dhcp=true 2>&1; then
        log_success "$MSG_DHCP_V4_ON"
    else
        log_warning "$MSG_DHCP_V4_FAIL"
    fi

    # IPv6 DHCP (stateful)
    if incus network set "$IFACE" ipv6.dhcp.stateful=true 2>&1; then
        log_success "$MSG_DHCP_V6_ON"
    else
        log_warning "$MSG_DHCP_V6_FAIL"
    fi
}

# ─── Применение правил UFW ──────────────────────────
run_cmd() {
    log_info "$MSG_RULE" "$*"
    if "$@" 2>&1; then
        log_success "$MSG_OK"
    else
        log_warning "$MSG_CMD_FAIL" "$*"
    fi
}

# Удаляет UFW-правило для порта, только если оно существует (иначе ufw ругается "nonexistent")
delete_ufw_port() {
    local port="$1"
    if ufw status 2>/dev/null | grep -qE "(^|[[:space:]])${port}/tcp([[:space:]]|$)"; then
        run_cmd ufw delete allow in proto tcp to any port "$port"
    fi
}

# ─── Запрет ICMP echo (ping) для secure-режима ──────
# UFW CLI не может запретить ping: разрешающие правила стоят в before-* цепочках
# раньше ufw-user-*. Поэтому правим /etc/ufw/before.rules (+ before6.rules для IPv6),
# вставляя DROP-правила в начало цепочек (после "# End required lines").
ICMP_MARKER_START="# === incus-firewall: block ICMP echo (secure mode) ==="
ICMP_MARKER_END="# === end incus-firewall ICMP block ==="

# Устанавливает блок запрета ICMP echo. Возвращает 0 если установил, 1 если уже был.
# in_chain — INPUT-цепочка (контейнер→хост, извне→хост), fwd_chain — FORWARD (контейнер→контейнер).
icmp_block_install() {
    local file="$1" in_chain="$2" fwd_chain="$3" proto="$4" icmptype="$5"
    if grep -qF "$ICMP_MARKER_START" "$file"; then
        return 1
    fi
    local tmp
    tmp=$(mktemp)
    awk -v iface="$IFACE" -v wan="$WAN_IFACE" -v in_chain="$in_chain" -v fwd_chain="$fwd_chain" \
        -v proto="$proto" -v icmptype="$icmptype" -v s="$ICMP_MARKER_START" -v e="$ICMP_MARKER_END" '
        /^# End required lines$/ {
            print
            print ""
            print s
            print "-A " in_chain " -i " iface " -p " proto " --" proto "-type " icmptype " -j DROP"
            print "-A " in_chain " -i " wan " -p " proto " --" proto "-type " icmptype " -j DROP"
            print "-A " fwd_chain " -i " iface " -o " iface " -p " proto " --" proto "-type " icmptype " -j DROP"
            print e
            next
        }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    return 0
}

# Удаляет блок запрета ICMP echo. Возвращает 0 если удалил, 1 если не было.
icmp_block_remove() {
    local file="$1"
    if ! grep -qF "$ICMP_MARKER_START" "$file"; then
        return 1
    fi
    sed -i "/^${ICMP_MARKER_START}$/,/^${ICMP_MARKER_END}$/d" "$file"
    return 0
}

# Удаляет правила, специфичные для режима доступа (остатки от другого режима)
cleanup_mode_rules() {
    # WAN-интерфейс нужен для очистки secure-правил, но detect_wan вызывается только в secure-режиме.
    # Определяем его здесь по возможности, чтобы переход secure→другой режим убирал и secure-правила.
    if [ -z "$WAN_IFACE" ]; then
        WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    fi
    if [ -n "$V4_NET_CIDR" ]; then
        ufw route delete allow from any to "$V4_NET_CIDR" >/dev/null 2>&1 || true
        if [ -n "$WAN_IFACE" ]; then
            ufw route delete allow in on "$WAN_IFACE" to "$V4_NET_CIDR" >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "$V6_CIDR" ]; then
        ufw route delete allow from any to "$V6_CIDR" >/dev/null 2>&1 || true
        if [ -n "$WAN_IFACE" ]; then
            ufw route delete allow in on "$WAN_IFACE" to "$V6_CIDR" >/dev/null 2>&1 || true
        fi
    fi
    if [ -n "$V4_GATEWAY" ]; then
        ufw delete allow in on "$IFACE" to "$V4_GATEWAY" port 53 >/dev/null 2>&1 || true
        ufw delete allow in on "$IFACE" to "$V4_GATEWAY" proto tcp >/dev/null 2>&1 || true
        ufw delete allow in on "$IFACE" to "$V4_GATEWAY" proto udp >/dev/null 2>&1 || true
    fi
    # Широкие правила full-режима (убираем при переходе в dns-only/ports)
    ufw delete allow in on "$IFACE" >/dev/null 2>&1 || true
    ufw route delete allow in on "$IFACE" >/dev/null 2>&1 || true
    # secure-режим: исходящий форвардинг на WAN (убираем при переходе в другой режим)
    if [ -n "$WAN_IFACE" ]; then
        ufw route delete allow out on "$WAN_IFACE" >/dev/null 2>&1 || true
    fi
    # secure-режим: запрет ICMP echo (убираем при переходе в другой режим)
    if [ "$ACCESS_MODE" != "secure" ]; then
        local changed=0
        icmp_block_remove /etc/ufw/before.rules && changed=1
        icmp_block_remove /etc/ufw/before6.rules && changed=1
        if [ "$changed" = "1" ]; then
            ufw reload
        fi
    fi
}

apply_rules() {
    log_info "$MSG_APPLY" "$IFACE"
    cleanup_mode_rules
    # SSH (детектируемый порт) — открыть в UFW, чтобы не потерять доступ после ufw enable
    local sp
    read -r -p "$(printf "$MSG_ASK_SSH" "${SSH_PORTS[*]}")" ANSWER
    case "${ANSWER,,}" in
        n|no)
            log_info "$MSG_SSH_SKIP"
            ;;
        *)
            for sp in "${SSH_PORTS[@]}"; do
                run_cmd ufw allow in proto tcp to any port "$sp"
            done
            ;;
    esac
    # Хост всегда может отправлять трафик на мост (ответы, host-initiated)
    run_cmd ufw allow out on "$IFACE"
    # DHCP (UDP 67) нужен во всех режимах — контейнеры получают IP по broadcast
    run_cmd ufw allow in on "$IFACE" proto udp to any port 67
    # DHCPv6 (UDP 546,547) — без него контейнеры с ipv6.dhcp.stateful
    # не получают IPv6 в локалке (их SOLICIT на 547 режется UFW)
    run_cmd ufw allow in on "$IFACE" proto udp to any port 546,547

    if [ "$ACCESS_MODE" = "full" ]; then
        run_cmd ufw allow in on "$IFACE"
        run_cmd ufw route allow in on "$IFACE"
        if [ -n "$V4_NET_CIDR" ]; then
            run_cmd ufw route allow from any to "$V4_NET_CIDR"
        fi
        if [ -n "$V6_CIDR" ]; then
            run_cmd ufw route allow from any to "$V6_CIDR"
        fi
    elif [ "$ACCESS_MODE" = "secure" ]; then
        # контейнеры → интернет (исходящие NEW): форвардинг на WAN.
        # Не `in on IFACE` — иначе разрешится и контейнер→контейнер.
        run_cmd ufw route allow out on "$WAN_IFACE"
        # интернет → контейнеры: только пробросы с WAN (работают в реальном времени).
        # Не `from any` — иначе контейнеры достанут друг друга.
        if [ -n "$V4_NET_CIDR" ]; then
            run_cmd ufw route allow in on "$WAN_IFACE" to "$V4_NET_CIDR"
        fi
        if [ -n "$V6_CIDR" ]; then
            run_cmd ufw route allow in on "$WAN_IFACE" to "$V6_CIDR"
        fi
        # контейнеры → хост: только DNS к gateway (чтобы не ломать интернет).
        # Остальные порты хоста для контейнеров закрыты.
        if [ -n "$V4_GATEWAY" ]; then
            run_cmd ufw allow in on "$IFACE" to "$V4_GATEWAY" port 53
        fi
        # Запрет ping (невидимость): ICMP echo блокируется в before-* цепочках.
        # Между контейнерами, от контейнеров к хосту и извне к хосту.
        local changed=0
        icmp_block_install /etc/ufw/before.rules ufw-before-input ufw-before-forward icmp echo-request && changed=1
        icmp_block_install /etc/ufw/before6.rules ufw6-before-input ufw6-before-forward icmpv6 echo-request && changed=1
        if [ "$changed" = "1" ]; then
            ufw reload
        fi
    elif [ "$ACCESS_MODE" = "dns-only" ]; then
        if [ -n "$V4_GATEWAY" ]; then
            run_cmd ufw allow in on "$IFACE" to "$V4_GATEWAY" port 53
        fi
    elif [ "$ACCESS_MODE" = "tcp-udp" ]; then
        if [ -n "$V4_GATEWAY" ]; then
            run_cmd ufw allow in on "$IFACE" to "$V4_GATEWAY" proto tcp
            run_cmd ufw allow in on "$IFACE" to "$V4_GATEWAY" proto udp
        fi
    fi
}

# ─── Порт панели IncusUI ───────────────────────────
# Текущий порт панели из core.https_address (например :8443 → 8443)
current_panel_port() {
    local addr
    addr=$(incus config get core.https_address 2>/dev/null) || true
    [ -n "$addr" ] || return 1
    echo "${addr##*:}"
}

# Промпт: Enter = оставить текущий порт, yes = порт по умолчанию, no = закрыть панель.
# После задания порта — отдельный вопрос: открывать ли его наружу (по умолчанию да;
# no — порт не открывается, существующее правило закрывается).
ask_panel() {
    local cur
    cur=$(current_panel_port) || true
    read -r -p "$(printf "$MSG_ASK_PANEL" "${cur:-—}" "$DEFAULT_PANEL_PORT")" PANEL_INPUT
    case "${PANEL_INPUT,,}" in
        "")
            # пропуск — оставляем текущее состояние как есть
            ;;
        n|no)
            # закрыть панель: снять адрес + удалить её UFW-правило
            if [ -n "$cur" ]; then
                delete_ufw_port "$cur"
            fi
            incus config unset core.https_address 2>/dev/null || true
            log_success "$MSG_PANEL_CLOSED"
            ;;
        *)
            case "${PANEL_INPUT,,}" in
                y|yes) PANEL_INPUT="$DEFAULT_PANEL_PORT" ;;
            esac
            if ! [[ "$PANEL_INPUT" =~ ^[0-9]+$ ]] || [ "$PANEL_INPUT" -lt 1 ] || [ "$PANEL_INPUT" -gt 65535 ]; then
                log_error "$MSG_PANEL_INVALID"
                return 1
            fi
            # при смене порта убираем старое правило, чтобы не оставлять открытый порт
            if [ -n "$cur" ] && [ "$cur" != "$PANEL_INPUT" ]; then
                delete_ufw_port "$cur"
            fi
            if incus config set core.https_address=":$PANEL_INPUT" 2>/dev/null; then
                log_success "$MSG_PANEL_SET" "$PANEL_INPUT"
            else
                log_warning "$MSG_PANEL_SET_FAIL"
            fi
            # отдельный вопрос: открывать ли порт наружу (по умолчанию — да)
            read -r -p "$(printf "$MSG_ASK_PANEL_OPEN" "$PANEL_INPUT")" OPEN_ANSWER
            case "${OPEN_ANSWER,,}" in
                n|no)
                    # не открывать: сносим правило, если порт был открыт ранее
                    delete_ufw_port "$PANEL_INPUT"
                    log_info "$MSG_PANEL_LOCAL" "$PANEL_INPUT"
                    ;;
                *)
                    run_cmd ufw allow in proto tcp to any port "$PANEL_INPUT"
                    ;;
            esac
            ;;
    esac
}

# ─── Главная ────────────────────────────────────────
main() {
    init_lang
    echo ""
    echo -e "${GREEN}╔═════════════════════════════╗${NC}"
    echo -e "${GREEN}║ Incus Bridge UFW Setup v2.0 ║${NC}"
    echo -e "${GREEN}║  UFW + br_netfilter + DHCP  ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════╝${NC}"
    echo ""

    if [ "$EUID" -ne 0 ]; then
        log_error "$MSG_ROOT_REQUIRED"
        exit 1
    fi

    install_deps

    if ufw status | grep -qi "inactive"; then
        log_warning "$MSG_UFW_INACTIVE"
    fi

    ask_iface
    ask_access
    ask_dhcp
    detect_networks
    detect_ssh_port
    if [ "$ACCESS_MODE" = "secure" ]; then
        detect_wan
    fi
    setup_kernel
    setup_dhcp
    apply_rules
    ask_panel
    log_success "$MSG_DONE"
}

# ─── Оформление вывода ──────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { printf "${GREEN}>>> [UFS]${NC} $1\n" "${@:2}" >&2; }
log_success() { printf "${GREEN}>>> [UFS]${NC} ✅ $1\n" "${@:2}" >&2; }
log_warning() { printf "${YELLOW}>>> [UFS]${NC} ⚠️ $1\n" "${@:2}" >&2; }
log_error() { printf "${RED}>>> [UFS]${NC} ❌ $1\n" "${@:2}" >&2; }

# ─── Локализация ─────────────────────────────────────
init_lang() {
    if [[ "$LANG" == ru_RU* ]]; then
        MSG_ASK_IFACE="Имя интерфейса моста (Enter = ${DEFAULT_IFACE}): "
        MSG_IFACE_NOT_FOUND="Интерфейс '%s' не найден"
        MSG_NO_IPV4="На интерфейсе %s нет IPv4 адреса"
        MSG_NO_IPV6="На интерфейсе %s нет IPv6 адреса (пропускаем)"
        MSG_SSH_PORT="SSH порт: %s"
        MSG_ASK_SSH="Добавить UFW-правило для SSH порта %s? [Y/n]: "
        MSG_SSH_SKIP="SSH-правило пропущено"
        MSG_ASK_PANEL="Порт панели IncusUI (текущий: %s; Enter = оставить, yes = %s, число = сменить, no = закрыть): "
        MSG_ASK_PANEL_OPEN="Открыть порт панели %s наружу в UFW? [Y/n]: "
        MSG_PANEL_INVALID="Некорректный порт (1-65535)"
        MSG_PANEL_SET="Порт панели задан: %s"
        MSG_PANEL_LOCAL="Порт панели %s задан, наружу не открыт (доступ через SSH-туннель)"
        MSG_PANEL_CLOSED="Порт панели закрыт"
        MSG_PANEL_SET_FAIL="Не удалось задать порт панели"
        MSG_APPLY="Применение правил UFW для интерфейса %s"
        MSG_RULE="Правило: %s"
        MSG_OK="OK"
        MSG_CMD_FAIL="Команда не выполнена: %s"
        MSG_ROOT_REQUIRED="Требуются права root (sudo)"
        MSG_BRNF_SETUP="Настройка br_netfilter..."
        MSG_BRNF_MODPROBE_FAIL="Не удалось загрузить модуль br_netfilter"
        MSG_BRNF_AUTOLOAD_ADDED="br_netfilter добавлен в автозагрузку"
        MSG_BRNF_AUTOLOAD_EXISTS="br_netfilter уже в автозагрузке"
        MSG_DHCP_DISABLED="DHCP отключен по запросу"
        MSG_DHCP_ENABLING="Включение DHCP на мосте %s..."
        MSG_DHCP_V4_ON="IPv4 DHCP включен"
        MSG_DHCP_V4_FAIL="Не удалось включить IPv4 DHCP"
        MSG_DHCP_V6_ON="IPv6 DHCP (stateful) включен"
        MSG_DHCP_V6_FAIL="Не удалось включить IPv6 DHCP (возможно не поддерживается)"
        MSG_DONE="Готово. Правила применены."
        MSG_UFW_INACTIVE="UFW неактивен — правила будут добавлены и применятся после 'ufw enable'"
        MSG_DEPS_MISSING="Не найдены утилиты:"
        MSG_ASK_INSTALL_DEPS="Установить их автоматически? [Y/n]: "
        MSG_DEPS_ABORT="Установка отменена"
        MSG_DEPS_STILL_MISSING="Утилиты не установились:"
        MSG_DEPS_INSTALLED="Зависимости установлены"
        MSG_ASK_ACCESS="Режим доступа [F]ull / [S]ecure (изоляция+пробросы) / [D]ns-only / [P]orts (TCP+UDP)? [f/S/d/p]: "
        MSG_ASK_DHCP="Включить DHCP на мосте (incus network set ... dhcp)? [Y/n]: "
        MSG_WAN_NOT_FOUND="Не удалось определить WAN-интерфейс (нет default route)"
        MSG_WAN_IFACE="WAN-интерфейс: %s"
    else
        MSG_ASK_IFACE="Bridge interface name (Enter = ${DEFAULT_IFACE}): "
        MSG_IFACE_NOT_FOUND="Interface '%s' not found"
        MSG_NO_IPV4="Interface %s has no IPv4 address"
        MSG_NO_IPV6="Interface %s has no IPv6 address (skipping)"
        MSG_SSH_PORT="SSH port: %s"
        MSG_ASK_SSH="Add UFW rule for SSH port %s? [Y/n]: "
        MSG_SSH_SKIP="SSH rule skipped"
        MSG_ASK_PANEL="IncusUI panel port (current: %s; Enter = keep, yes = %s, number = change, no = close): "
        MSG_ASK_PANEL_OPEN="Open panel port %s to the outside in UFW? [Y/n]: "
        MSG_PANEL_INVALID="Invalid port (1-65535)"
        MSG_PANEL_SET="Panel port set: %s"
        MSG_PANEL_LOCAL="Panel port %s set, not exposed (use SSH tunnel)"
        MSG_PANEL_CLOSED="Panel port closed"
        MSG_PANEL_SET_FAIL="Failed to set panel port"
        MSG_APPLY="Applying UFW rules for interface %s"
        MSG_RULE="Rule: %s"
        MSG_OK="OK"
        MSG_CMD_FAIL="Command failed: %s"
        MSG_ROOT_REQUIRED="Root privileges required (sudo)"
        MSG_BRNF_SETUP="Setting up br_netfilter..."
        MSG_BRNF_MODPROBE_FAIL="Failed to load br_netfilter module"
        MSG_BRNF_AUTOLOAD_ADDED="br_netfilter enabled at boot"
        MSG_BRNF_AUTOLOAD_EXISTS="br_netfilter already enabled at boot"
        MSG_DHCP_DISABLED="DHCP disabled by request"
        MSG_DHCP_ENABLING="Enabling DHCP on bridge %s..."
        MSG_DHCP_V4_ON="IPv4 DHCP enabled"
        MSG_DHCP_V4_FAIL="Failed to enable IPv4 DHCP"
        MSG_DHCP_V6_ON="IPv6 DHCP (stateful) enabled"
        MSG_DHCP_V6_FAIL="Failed to enable IPv6 DHCP (may not be supported)"
        MSG_DONE="Done. Rules applied."
        MSG_UFW_INACTIVE="UFW is inactive — rules will be added and take effect after 'ufw enable'"
        MSG_DEPS_MISSING="Missing utilities:"
        MSG_ASK_INSTALL_DEPS="Install them automatically? [Y/n]: "
        MSG_DEPS_ABORT="Installation aborted"
        MSG_DEPS_STILL_MISSING="Utilities still missing:"
        MSG_DEPS_INSTALLED="Dependencies installed"
        MSG_ASK_ACCESS="Access mode [F]ull / [S]ecure (isolation+forwards) / [D]ns-only / [P]orts (TCP+UDP)? [f/S/d/p]: "
        MSG_ASK_DHCP="Enable DHCP on bridge (incus network set ... dhcp)? [Y/n]: "
        MSG_WAN_NOT_FOUND="Could not determine WAN interface (no default route)"
        MSG_WAN_IFACE="WAN interface: %s"
    fi
}

main "$@"
