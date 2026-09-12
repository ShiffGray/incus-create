#!/bin/bash
#
# ssh-keys v2.0
# Генерация ed25519 SSH-ключей + authorized_keys + HTTP экспорт
#

NAME=""
PASSPHRASE=""
OUTDIR="$HOME/.ssh/keys"
HOSTNAME=$(hostname -s 2>/dev/null || echo "host")
COUNT=1
BASE_NAME=""
SERVE_ALL=0
EXPORT_DIR=""
GENERATED_NAMES=()
SSHD_CONFIG="/etc/ssh/sshd_config"
AUTH_KEYS_FILE="$HOME/.ssh/authorized_keys"
GENERATE="yes" # yes = генерировать, no = только синхронизация
SSH_PORTS=() # активные SSH-порты из sshd_config (для UFW-правила)
OLD_SSH_PORTS=() # порты, бывшие активными до смены (закрываются в UFW после открытия нового)

# ─── Флаги ─────────────────────────────────────────
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n) if [ $# -lt 2 ]; then log_error "$MSG_UNKNOWN_FLAG -n"; exit 1; fi; NAME="$2"; shift 2 ;;
            -o) OUTDIR="$2"; shift 2 ;;
            --serve|-s) SERVE_ALL=1; shift ;;
            --help|-h) echo "$HELP_USAGE"; echo "$HELP_FLAGS"; exit 0 ;;
            *) log_error "$MSG_UNKNOWN_FLAG $1"; exit 1 ;;
        esac
    done
}

# ─── Запрос данных ─────────────────────────────────
ask_name() {
    if [ -z "$NAME" ]; then
        read -r -p "$MSG_ASK_NAME $HOSTNAME): " INPUT
        if [ -z "$INPUT" ]; then INPUT="$HOSTNAME"; fi
        NAME="$INPUT"
    fi

    COUNT=1
    if [[ "$NAME" =~ ^(.+)\*([0-9]+)$ ]]; then
        NAME="${BASH_REMATCH[1]}"
        COUNT="${BASH_REMATCH[2]}"
    elif [[ "$NAME" =~ ^\*([0-9]+)$ ]]; then
        NAME="$HOSTNAME"
        COUNT="${BASH_REMATCH[1]}"
    fi

    if [ "$COUNT" -lt 1 ] 2>/dev/null; then
        log_error "$MSG_COUNT_INVALID"
        exit 1
    fi

    BASE_NAME="$NAME"
}
ask_passphrase() {
    while true; do
        read -s -p "$MSG_ASK_PASS $MSG_ENTER_NOPASS): " PASSPHRASE; echo ""
        # без пароля — сразу выход
        if [ -z "$PASSPHRASE" ]; then
            return
        fi
        local PASS2=""
        read -s -p "$MSG_ASK_PASS_CONFIRM: " PASS2; echo ""
        # пропуск подтверждения — принимаем введённый пароль
        if [ -z "$PASS2" ]; then
            return
        fi
        if [ "$PASSPHRASE" = "$PASS2" ]; then
            return
        fi
        log_warning "$MSG_PASS_MISMATCH"
        # не совпало — вводим пароль по новой
    done
}
ask_generate() {
    while true; do
        read -r -p "$MSG_ASK_GENERATE" ANSWER
        case "${ANSWER,,}" in
            exit|close|clear)
                log_info "$MSG_GEN_CANCEL"
                exit 0
                ;;
            n|no)
                GENERATE="no"
                return
                ;;
            y|yes|"")
                GENERATE="yes"
                return
                ;;
            *)
                log_warning "$MSG_GEN_INVALID"
                ;;
        esac
    done
}

# ─── Установка зависимостей ────────────────────────
install_deps() {
    if command -v ssh-keygen &>/dev/null; then
        return
    fi

    log_warning "ssh-keygen not found"
    read -r -p "Install openssh-client automatically? [Y/n]: " ANSWER
    if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
        log_error "Installation aborted"
        exit 1
    fi

    apt-get update
    apt-get install -y openssh-client
    if ! command -v ssh-keygen &>/dev/null; then
        log_error "ssh-keygen still not found after install"
        exit 1
    fi
    log_success "ssh-keygen installed"
}

# ─── Генерация ─────────────────────────────────────
gen_key() {
    log_info "$MSG_GEN_START $NAME"
    mkdir -p "$OUTDIR"
    local KEY="$OUTDIR/$NAME"
    local PUB="$OUTDIR/$NAME.pub"
    rm -f "$KEY" "$PUB"
    if ! ssh-keygen -t ed25519 -f "$KEY" -N "$PASSPHRASE" -C "$NAME@$HOSTNAME" -a 120 -q; then
        log_error "$MSG_GEN_FAIL" "$NAME"
        return 1
    fi
    chmod 600 "$KEY"
    chmod 644 "$PUB"
    log_success "$MSG_GEN_KEY $KEY"
    log_success "$MSG_GEN_PUB $PUB"
}

# ─── Настройка sshd (authorized_keys) ─────────────
# sshd читает один файл authorized_keys. Мы пересобираем его из папки ключей:
# для каждого *.pub пишем строку-маркер "# ssh-keys: <имя>" и сам ключ.
# По маркеру видно, какой строке какой ключ соответствует, а строки для
# файлов, которых больше нет в папке, исчезают автоматически.
reload_sshd() {
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || service sshd reload 2>/dev/null
}

# Добавляет/заменяет директиву в sshd_config. Возвращает 1, если что-то изменилось.
set_sshd_opt() {
    local key="$1" value="$2"
    local line="${key} ${value}"
    # 1) активная директива уже есть — заменяем её значение
    if grep -qE "^[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
        local cur
        cur=$(sed -nE "s|^[[:space:]]*${key}[[:space:]]+||p" "$SSHD_CONFIG" | tail -1)
        if [ "$cur" = "$value" ]; then
            return 0
        fi
        sed -i "s|^[[:space:]]*${key}[[:space:]]\+.*|${line}|" "$SSHD_CONFIG"
        return 1
    fi
    # 2) активной нет — вставляем после комментария #key, если такой есть
    local anchor
    anchor=$(grep -nE "^[[:space:]]*#${key}([[:space:]]|$)" "$SSHD_CONFIG" | tail -1 | cut -d: -f1)
    if [ -n "$anchor" ]; then
        sed -i "${anchor}a ${line}" "$SSHD_CONFIG"
        return 1
    fi
    # 3) ни активной, ни комментария — добавляем в конец
    echo "${line}" >> "$SSHD_CONFIG"
    return 1
}

# Пересобирает authorized_keys из папки ключей: для каждого *.pub пишет
# строку-маркер "# ssh-keys: <имя>" и сам ключ. Строки для файлов, которых
# больше нет в папке, исчезают автоматически.
sync_auth_keys() {
    mkdir -p "$OUTDIR"
    mkdir -p "$(dirname "$AUTH_KEYS_FILE")"
    : > "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"
    local pub base
    for pub in "$OUTDIR"/*.pub; do
        [ -f "$pub" ] || continue
        base=$(basename "$pub" .pub)
        echo "# ssh-keys: $base" >> "$AUTH_KEYS_FILE"
        cat "$pub" >> "$AUTH_KEYS_FILE"
    done
}

setup_sshd() {
    sync_auth_keys
    local changed=0
    set_sshd_opt "PubkeyAuthentication" "yes" || changed=1

    if [ "$changed" -eq 1 ]; then
        if reload_sshd; then
            log_success "$MSG_SSHD_SETUP"
        else
            log_warning "$MSG_SSHD_RELOAD_FAIL"
        fi
    else
        log_info "$MSG_SSHD_ALREADY"
    fi
}

# ─── Определение активных SSH-портов ───────────────
# sshd может слушать несколько портов; drop-in'ы перекрывают основной конфиг.
detect_ssh_port() {
    SSH_PORTS=()
    local conf port
    for conf in "$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf; do
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
}

# ─── Смена SSH порта (без UFW) ─────────────────────
change_ssh_port() {
    local new_port="$1"
    local op anchor found=0
    detect_ssh_port
    for op in "${SSH_PORTS[@]}"; do
        [ "$op" = "$new_port" ] && found=1
    done

    if [ "$found" -eq 1 ]; then
        log_info "$MSG_SSH_ALREADY" "$new_port"
        return 0
    fi

    # запоминаем старые порты, чтобы закрыть их в UFW после открытия нового
    OLD_SSH_PORTS=("${SSH_PORTS[@]}")

    if ! sshd -t 2>/dev/null; then
        log_error "$MSG_SSH_CONFIG_INVALID"
        return 1
    fi

    log_warning "$MSG_SSH_CHANGE_WARN" "$new_port"

    # Проверка ДО изменений: если порт занят НЕ sshd — отказ (иначе после
    # ребута sshd не поднимется: Address already in use; аудит-ssh-лок-аут)
    if ss -tln 2>/dev/null | grep -q ":$new_port\b" \
       && ! ss -tlnp 2>/dev/null | grep -E ":$new_port\b" | grep -q sshd; then
        log_error "$MSG_SSH_PORT_BUSY" "$new_port"
        return 1
    fi

    # Фаза 1: добавляем новый порт (старые остаются), reload — соединение сохраняется
    # Вставляем рядом с последней строкой Port (активной или закомментированной)
    anchor=$(grep -nE '^[[:space:]]*#?[[:space:]]*Port[[:space:]]' "$SSHD_CONFIG" | tail -1 | cut -d: -f1)
    if [ -n "$anchor" ]; then
        sed -i "${anchor}a Port $new_port" "$SSHD_CONFIG"
    else
        echo "Port $new_port" >> "$SSHD_CONFIG"
    fi
    if ! sshd -t 2>/dev/null; then
        log_error "$MSG_SSH_CONFIG_INVALID"
        return 1
    fi
    if ! reload_sshd; then
        log_error "$MSG_SSH_RELOAD_FAIL"
        return 1
    fi
    sleep 1
    if ! ss -tlnp 2>/dev/null | grep -E ":$new_port\b" | grep -q sshd; then
        # Слушает не sshd (или не слушает вовсе) — откатываем добавленную строку
        sed -i "\|^Port ${new_port}$|d" "$SSHD_CONFIG"
        if ! sshd -t 2>/dev/null; then
            log_error "$MSG_SSH_CONFIG_INVALID"
        else
            reload_sshd 2>/dev/null || true
        fi
        log_error "$MSG_SSH_LISTEN_FAIL" "$new_port"
        return 1
    fi
    log_success "$MSG_SSH_LISTENING" "$new_port"

    # Фаза 2: убираем старые порты (новый оставляем активным), reload
    for conf in "$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$conf" ] || continue
        sed -i "/^[[:space:]]*Port[[:space:]]\+${new_port}[[:space:]]*$/!s/^\([[:space:]]*Port[[:space:]]\+\)/#\1/" "$conf"
    done
    if ! sshd -t 2>/dev/null; then
        log_error "$MSG_SSH_CONFIG_INVALID"
        return 1
    fi
    if ! reload_sshd; then
        log_error "$MSG_SSH_RELOAD_FAIL"
        return 1
    fi
    log_success "$MSG_SSH_CHANGED" "$new_port"
}

# ─── Промпты SSH ───────────────────────────────────
ask_ssh_port() {
    read -r -p "$MSG_ASK_SSH_PORT" ANSWER
    if [ -z "$ANSWER" ]; then
        return
    fi
    if [[ "$ANSWER" =~ ^[0-9]+$ ]] && [ "$ANSWER" -ge 1 ] && [ "$ANSWER" -le 65535 ]; then
        change_ssh_port "$ANSWER" || log_warning "$MSG_SSH_CHANGE_FAIL"
    else
        log_error "$MSG_PORT_INVALID"
    fi
}

# ─── Установка UFW при необходимости ──────────────
# Если ufw отсутствует и он реально нужен — ставим (как в incus-firewall.sh).
ensure_ufw() {
    if command -v ufw &>/dev/null; then
        return 0
    fi
    log_info "$MSG_UFW_INSTALLING"
    if apt-get install -y ufw >/dev/null 2>&1; then
        log_success "$MSG_UFW_INSTALLED"
    else
        log_warning "$MSG_UFW_INSTALL_FAIL"
        return 1
    fi
}

# ─── Открытие SSH-порта в UFW ─────────────────────
# Чтобы не потерять доступ после ufw enable (как в incus-firewall.sh).
ask_ufw_ssh() {
    if ! ensure_ufw; then
        return
    fi
    detect_ssh_port
    local sp
    read -r -p "$(printf "$MSG_ASK_UFW_SSH" "${SSH_PORTS[*]}")" ANSWER
    case "${ANSWER,,}" in
        n|no)
            log_info "$MSG_UFW_SSH_SKIP"
            ;;
        *)
            for sp in "${SSH_PORTS[@]}"; do
                if ufw allow in proto tcp to any port "$sp" 2>&1; then
                    log_success "$MSG_UFW_SSH_OPEN" "$sp"
                else
                    log_warning "$MSG_UFW_SSH_FAIL" "$sp"
                fi
            done
            # закрываем старые порты (после смены), чтобы не оставлять открытыми
            if [ "${#OLD_SSH_PORTS[@]}" -gt 0 ]; then
                for sp in "${OLD_SSH_PORTS[@]}"; do
                    case " ${SSH_PORTS[*]} " in
                        *" $sp "*) ;;
                        *)
                            if ufw status 2>/dev/null | grep -qE "(^|[[:space:]])${sp}/tcp([[:space:]]|$)"; then
                                if ufw delete allow in proto tcp to any port "$sp" 2>&1; then
                                    log_success "$MSG_UFW_SSH_CLOSED" "$sp"
                                else
                                    log_warning "$MSG_UFW_SSH_CLOSE_FAIL" "$sp"
                                fi
                            fi
                            ;;
                    esac
                done
            fi
            # SSH-порт открыт — можно безопасно включить ufw
            ask_ufw_enable
            ;;
    esac
}

# ─── Включение UFW ────────────────────────────────
# Вызывается только после открытия SSH-порта, чтобы не потерять доступ.
ask_ufw_enable() {
    if ! ensure_ufw; then
        return
    fi
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
        log_info "$MSG_UFW_ALREADY_ACTIVE"
        return
    fi
    read -r -p "$MSG_ASK_UFW_ENABLE" ANSWER
    case "${ANSWER,,}" in
        n|no)
            log_info "$MSG_UFW_ENABLE_SKIP"
            ;;
        *)
            if ufw enable 2>&1; then
                log_success "$MSG_UFW_ENABLED"
            else
                log_warning "$MSG_UFW_ENABLE_FAIL"
            fi
            ;;
    esac
}

ask_password_auth() {
    read -r -p "$MSG_ASK_PASSWORD_AUTH" ANSWER
    case "${ANSWER,,}" in
        y|yes)
            if set_sshd_opt "PasswordAuthentication" "no"; then
                log_info "$MSG_PASSWORD_AUTH_ALREADY"
            else
                reload_sshd
                log_success "$MSG_PASSWORD_AUTH_DISABLED"
            fi
            ;;
        *)
            log_info "$MSG_PASSWORD_AUTH_KEEP"
            ;;
    esac
}

# ─── HTTP экспорт ──────────────────────────────────
export_http() {
    if ! command -v python3 &>/dev/null; then
        log_warning "$MSG_EXPORT_HTTP_NO_PYTHON"
        return
    fi

    while true; do
        read -r -p "$MSG_EXPORT_HTTP_PORT" PORT
        if [ -z "$PORT" ]; then
            return
        fi

        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
            log_error "$MSG_EXPORT_HTTP_INVALID_PORT"
            continue
        fi

        if command -v ss &>/dev/null && ss -tlnp | grep -qE "[:.]$PORT\b"; then
            log_error "$MSG_EXPORT_HTTP_PORT_BUSY"
            continue
        elif command -v lsof &>/dev/null && lsof -i :"$PORT" &>/dev/null; then
            log_error "$MSG_EXPORT_HTTP_PORT_BUSY"
            continue
        fi

        break
    done

    log_info "$MSG_EXPORT_HTTP_START $PORT"
    if [ "$SERVE_ALL" -eq 1 ]; then
        ( cd "$OUTDIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) &
    else
        EXPORT_DIR="$OUTDIR/.export-$$"
        mkdir -p "$EXPORT_DIR"
        local FNAME
        for FNAME in "${GENERATED_NAMES[@]}"; do
            cp "$OUTDIR/$FNAME" "$EXPORT_DIR/" 2>/dev/null || true
            cp "$OUTDIR/$FNAME.pub" "$EXPORT_DIR/" 2>/dev/null || true
        done
        ( cd "$EXPORT_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) &
    fi
    local PID=$!
    trap 'kill "$PID" 2>/dev/null || true; [ -n "$EXPORT_DIR" ] && rm -rf "$EXPORT_DIR"' INT TERM EXIT
    log_success "$MSG_EXPORT_HTTP_RUNNING http://localhost:$PORT"
    log_info "$MSG_EXPORT_HTTP_TUNNEL" "$PORT" "$PORT"
    echo ""
    read -r -p "$MSG_EXPORT_HTTP_STOP" _
    kill "$PID" 2>/dev/null || true
    trap - INT TERM EXIT
    log_success "$MSG_EXPORT_HTTP_STOPPED"
}

# ─── Главная ──────────────────────────────────────
main() {
    init_lang
    echo ""
    echo -e "${GREEN}╔═══════════════════════════╗${NC}"
    echo -e "${GREEN}║       ssh-keys v2.0       ║${NC}"
    echo -e "${GREEN}║ ed25519 + authorized_keys ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════╝${NC}"
    echo ""
    parse_flags "$@"

    if [ "$SERVE_ALL" -eq 1 ]; then
        export_http
        exit 0
    fi

    if [ "$EUID" -ne 0 ]; then
        log_error "$MSG_ROOT_REQUIRED"
        exit 1
    fi

    ask_generate

    install_deps
    if [ "$GENERATE" = "yes" ]; then
        ask_name; ask_passphrase
        mkdir -p "$OUTDIR"
        for i in $(seq 1 "$COUNT"); do
            candidate="$BASE_NAME"
            idx=0
            while true; do
                if [ -e "$OUTDIR/$candidate" ] || [ -e "$OUTDIR/$candidate.pub" ]; then
                    idx=$((idx + 1))
                    candidate="${BASE_NAME}${idx}"
                else
                    break
                fi
            done
            NAME="$candidate"
            GENERATED_NAMES+=("$NAME")
            gen_key || { log_error "Failed to generate key $i/$COUNT"; exit 1; }
        done
        setup_sshd
        ask_ssh_port
        ask_ufw_ssh
        ask_password_auth
        export_http
        if [ "$COUNT" -eq 1 ]; then
            log_success "$MSG_DONE $OUTDIR/$NAME{, .pub}"
        else
            log_success "$MSG_DONE_MULTI $OUTDIR/$BASE_NAME*{, .pub}"
        fi
    else
        # только синхронизация: пересобираем authorized_keys из папки ключей
        log_info "$MSG_SYNC_ONLY"
        sync_auth_keys
        log_success "$MSG_SYNC_DONE"
    fi
    echo ""
}

# ─── Оформление вывода ────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { printf "${GREEN}>>> [SSH]${NC} $1\n" "${@:2}" >&2; }
log_success() { printf "${GREEN}>>> [SSH]${NC} ✅ $1\n" "${@:2}" >&2; }
log_warning() { printf "${YELLOW}>>> [SSH]${NC} ⚠️ $1\n" "${@:2}" >&2; }
log_error() { printf "${RED}>>> [SSH]${NC} ❌ $1\n" "${@:2}" >&2; }

# ─── Локализация ─────────────────────────────────────
init_lang() {
    if [[ "$LANG" == ru_RU* ]]; then
        HELP_USAGE="ssh-keys -n <имя> [-o <папка>] [-s|--serve]"
        HELP_FLAGS=" -n <имя> имя файлов (обязательно)\n -s|--serve только экспорт всей папки через HTTP"
        MSG_UNKNOWN_FLAG="Неизвестный флаг:"
        MSG_ASK_NAME="Имя файла (напр."
        MSG_ASK_PASS="Passphrase для ключа (напр."
        MSG_ASK_PASS_CONFIRM="Подтвердите passphrase (Enter = пропустить): "
        MSG_PASS_MISMATCH="Passphrase не совпадает, попробуйте ещё раз"
        MSG_ENTER_NOPASS="Enter = без пароля"
        MSG_ASK_GENERATE="Сгенерировать ключ? [Y/n] (exit/close/clear = отмена): "
        MSG_GEN_CANCEL="Отменено, ничего не изменено"
        MSG_GEN_INVALID="Некорректный ответ (y/n/exit/close/clear)"
        MSG_SYNC_ONLY="Синхронизация без генерации"
        MSG_SYNC_DONE="Синхронизация завершена"
        MSG_GEN_START="Генерация ключа:"
        MSG_GEN_KEY="Приватный ключ:"
        MSG_GEN_PUB="Публичный ключ:"
        MSG_GEN_FAIL="Не удалось сгенерировать ключ %s"
        MSG_ROOT_REQUIRED="Требуются права root (sudo)"
        MSG_SSHD_SETUP="sshd настроен на чтение authorized_keys"
        MSG_SSHD_ALREADY="sshd уже настроен на чтение authorized_keys"
        MSG_SSHD_RELOAD_FAIL="Не удалось перезагрузить sshd"
        MSG_ASK_SSH_PORT="Сменить SSH порт (Enter = пропустить, число = сменить): "
        MSG_PORT_INVALID="Некорректный порт (1-65535)"
        MSG_SSH_ALREADY="Порт %s уже активен"
        MSG_SSH_CONFIG_INVALID="Конфиг sshd невалиден, смена порта отменена"
        MSG_SSH_CHANGE_WARN="SSH-порт меняется на %s — текущее соединение сохранится, новые подключения на новый порт."
        MSG_SSH_CHANGE_FAIL="Не удалось сменить SSH-порт, продолжаю"
        MSG_SSH_CHANGED="SSH-порт изменён на %s"
        MSG_SSH_LISTENING="sshd слушает порт %s"
        MSG_SSH_LISTEN_FAIL="sshd не подтверждён на порту %s"
        MSG_SSH_PORT_BUSY="Порт %s занят другим сервисом (не sshd) — смена порта отменена, иначе после перезагрузки SSH не поднимется"
        MSG_ASK_UFW_SSH="Добавить UFW-правило для SSH порта %s? [Y/n]: "
        MSG_UFW_SSH_SKIP="SSH-правило пропущено"
        MSG_UFW_SSH_OPEN="SSH-порт %s открыт в UFW"
        MSG_UFW_SSH_FAIL="Не удалось открыть SSH-порт %s в UFW"
        MSG_UFW_SSH_CLOSED="SSH-порт %s закрыт в UFW"
        MSG_UFW_SSH_CLOSE_FAIL="Не удалось закрыть SSH-порт %s в UFW"
        MSG_ASK_UFW_ENABLE="Включить UFW? [Y/n]: "
        MSG_UFW_ENABLE_SKIP="UFW не включён"
        MSG_UFW_ENABLED="UFW включён"
        MSG_UFW_ENABLE_FAIL="Не удалось включить UFW"
        MSG_UFW_ALREADY_ACTIVE="UFW уже активен"
        MSG_UFW_INSTALLING="UFW не установлен — устанавливаю..."
        MSG_UFW_INSTALLED="UFW установлен"
        MSG_UFW_INSTALL_FAIL="Не удалось установить UFW"
        MSG_ASK_PASSWORD_AUTH="Запретить вход по паролю? [y/N]: "
        MSG_PASSWORD_AUTH_DISABLED="Вход по паролю запрещён"
        MSG_PASSWORD_AUTH_ALREADY="Вход по паролю уже запрещён"
        MSG_PASSWORD_AUTH_KEEP="Вход по паролю оставлен"
        MSG_DONE="Готово:"
        MSG_DONE_MULTI="Готово. Ключи сохранены в:"
        MSG_COUNT_INVALID="Количество должно быть >= 1"
        MSG_EXPORT_HTTP_PORT="Порт для HTTP экспорта (Enter = пропустить): "
        MSG_EXPORT_HTTP_INVALID_PORT="Некорректный порт (1024-65535)"
        MSG_EXPORT_HTTP_PORT_BUSY="Порт занят, выберите другой"
        MSG_EXPORT_HTTP_NO_PYTHON="python3 не найден. Установите python3 для экспорта."
        MSG_EXPORT_HTTP_START="Запуск HTTP сервера на порту"
        MSG_EXPORT_HTTP_RUNNING="HTTP сервер запущен:"
        MSG_EXPORT_HTTP_TUNNEL="Для доступа с ПК выполните: ssh -L %s:127.0.0.1:%s user@server -N"
        MSG_EXPORT_HTTP_STOP="Нажмите Enter для остановки сервера..."
        MSG_EXPORT_HTTP_STOPPED="HTTP сервер остановлен"
    else
        HELP_USAGE="ssh-keys -n <name> [-o <dir>] [-s|--serve]"
        HELP_FLAGS=" -n <name> filename prefix (required)\n -s|--serve serve entire folder via HTTP"
        MSG_UNKNOWN_FLAG="Unknown flag:"
        MSG_ASK_NAME="Filename (e.g."
        MSG_ASK_PASS="Key passphrase (e.g."
        MSG_ASK_PASS_CONFIRM="Confirm passphrase (Enter = skip): "
        MSG_PASS_MISMATCH="Passphrases do not match, try again"
        MSG_ENTER_NOPASS="Enter = no passphrase"
        MSG_ASK_GENERATE="Generate key? [Y/n] (exit/close/clear = cancel): "
        MSG_GEN_CANCEL="Cancelled, nothing changed"
        MSG_GEN_INVALID="Invalid answer (y/n/exit/close/clear)"
        MSG_SYNC_ONLY="Sync only, no generation"
        MSG_SYNC_DONE="Sync complete"
        MSG_GEN_START="Generating key:"
        MSG_GEN_KEY="Private key:"
        MSG_GEN_PUB="Public key:"
        MSG_GEN_FAIL="Failed to generate key %s"
        MSG_ROOT_REQUIRED="Root required (sudo)"
        MSG_SSHD_SETUP="sshd configured to read authorized_keys"
        MSG_SSHD_ALREADY="sshd already configured to read authorized_keys"
        MSG_SSHD_RELOAD_FAIL="Failed to reload sshd"
        MSG_ASK_SSH_PORT="Change SSH port (Enter = skip, number = change): "
        MSG_PORT_INVALID="Invalid port (1-65535)"
        MSG_SSH_ALREADY="Port %s already active"
        MSG_SSH_CONFIG_INVALID="sshd config invalid, port change aborted"
        MSG_SSH_CHANGE_WARN="SSH port changing to %s — current connection stays, new connections on the new port."
        MSG_SSH_CHANGE_FAIL="Failed to change SSH port, continuing"
        MSG_SSH_CHANGED="SSH port changed to %s"
        MSG_SSH_LISTENING="sshd listening on port %s"
        MSG_SSH_LISTEN_FAIL="sshd not confirmed on port %s"
        MSG_SSH_PORT_BUSY="Port %s is busy by another service (not sshd) — port change aborted, otherwise SSH would not start after reboot"
        MSG_ASK_UFW_SSH="Add UFW rule for SSH port %s? [Y/n]: "
        MSG_UFW_SSH_SKIP="SSH rule skipped"
        MSG_UFW_SSH_OPEN="SSH port %s opened in UFW"
        MSG_UFW_SSH_FAIL="Failed to open SSH port %s in UFW"
        MSG_UFW_SSH_CLOSED="SSH port %s closed in UFW"
        MSG_UFW_SSH_CLOSE_FAIL="Failed to close SSH port %s in UFW"
        MSG_ASK_UFW_ENABLE="Enable UFW? [Y/n]: "
        MSG_UFW_ENABLE_SKIP="UFW not enabled"
        MSG_UFW_ENABLED="UFW enabled"
        MSG_UFW_ENABLE_FAIL="Failed to enable UFW"
        MSG_UFW_ALREADY_ACTIVE="UFW already active"
        MSG_UFW_INSTALLING="UFW not installed — installing..."
        MSG_UFW_INSTALLED="UFW installed"
        MSG_UFW_INSTALL_FAIL="Failed to install UFW"
        MSG_ASK_PASSWORD_AUTH="Disable password login? [y/N]: "
        MSG_PASSWORD_AUTH_DISABLED="Password login disabled"
        MSG_PASSWORD_AUTH_ALREADY="Password login already disabled"
        MSG_PASSWORD_AUTH_KEEP="Password login kept"
        MSG_DONE="Done:"
        MSG_DONE_MULTI="Done. Keys saved in:"
        MSG_COUNT_INVALID="Count must be >= 1"
        MSG_EXPORT_HTTP_PORT="Port for HTTP export (Enter = skip): "
        MSG_EXPORT_HTTP_INVALID_PORT="Invalid port (1024-65535)"
        MSG_EXPORT_HTTP_PORT_BUSY="Port is busy, choose another"
        MSG_EXPORT_HTTP_NO_PYTHON="python3 not found. Install python3 for export."
        MSG_EXPORT_HTTP_START="Starting HTTP server on port"
        MSG_EXPORT_HTTP_RUNNING="HTTP server running:"
        MSG_EXPORT_HTTP_TUNNEL="To access from PC run: ssh -L %s:127.0.0.1:%s user@server -N"
        MSG_EXPORT_HTTP_STOP="Press Enter to stop the server..."
        MSG_EXPORT_HTTP_STOPPED="HTTP server stopped"
    fi
}

main "$@"
