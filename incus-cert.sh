#!/bin/bash
#
# incus-cert v2.0
# Генерация ECDSA сертификатов + PFX
#

NAME=""
DESC=""
PASS=""
DAYS_INPUT=""
OUTDIR="$HOME/.ssh/incus-certs"
HOSTNAME=$(hostname -s 2>/dev/null || echo "host")
COUNT=1
BASE_NAME=""
SERVE_ALL=0
EXPORT_DIR=""
DAYS_SET=0
GENERATED_NAMES=()
CLEANUP_ENABLE="yes" # yes = зачистить из панели сертификаты, которых нет в папке
GENERATE="yes" # yes = генерировать, no = только синхронизация

# ─── Флаги ─────────────────────────────────────────
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n) if [ $# -lt 2 ]; then log_error "$MSG_UNKNOWN_FLAG -n"; exit 1; fi; NAME="$2"; shift 2 ;;
            -d) DAYS="$2"; DAYS_SET=1; shift 2 ;;
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
ask_desc() {
    read -r -p "$MSG_ASK_DESC ${HOSTNAME}_home, $MSG_ENTER_EQ_NAME): " DESC
    if [ -z "$DESC" ]; then DESC="$NAME"; fi
}
ask_password() {
    while true; do
        read -s -p "$MSG_ASK_PASS 123456, $MSG_ENTER_NOPASS): " PASS; echo ""
        # без пароля — сразу выход
        if [ -z "$PASS" ]; then
            return
        fi
        local PASS2=""
        read -s -p "$MSG_ASK_PASS_CONFIRM: " PASS2; echo ""
        # пропуск подтверждения — принимаем введённый пароль
        if [ -z "$PASS2" ]; then
            return
        fi
        if [ "$PASS" = "$PASS2" ]; then
            return
        fi
        log_warning "$MSG_PASS_MISMATCH"
        # не совпало — вводим пароль по новой
    done
}
ask_days() {
    if [ "$DAYS_SET" -eq 1 ]; then
        return
    fi
    read -r -p "$MSG_ASK_DAYS ${MSG_ASK_DAYS_MAX}): " DAYS_INPUT
    if [ -n "$DAYS_INPUT" ]; then
        DAYS="$DAYS_INPUT"
    else
        detect_max_days
        log_info "Auto-selected max supported days: $DAYS"
    fi
}
ask_cleanup() {
    read -r -p "$MSG_ASK_CLEANUP" CLEANUP_ANSWER
    case "${CLEANUP_ANSWER,,}" in
        n|no) CLEANUP_ENABLE="no" ;;
        *) CLEANUP_ENABLE="yes" ;;
    esac
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
    if command -v openssl &>/dev/null; then
        return
    fi

    log_warning "openssl not found"
    read -r -p "Install openssl automatically? [Y/n]: " ANSWER
    if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
        log_error "Installation aborted"
        exit 1
    fi

    apt-get update
    apt-get install -y openssl
    if ! command -v openssl &>/dev/null; then
        log_error "openssl still not found after install"
        exit 1
    fi
    log_success "openssl installed"
}

detect_max_days() {
    if ! command -v openssl &>/dev/null; then
        return
    fi
    local tmpdir
    tmpdir=$(mktemp -d) || return
    local test_days=(3650000 365000 36500 7300 3650 1000)
    local d
    for d in "${test_days[@]}"; do
        if openssl ecparam -genkey -name prime256v1 -out "$tmpdir/key" 2>/dev/null && \
           openssl req -new -key "$tmpdir/key" -out "$tmpdir/csr" -subj /CN=test 2>/dev/null && \
           openssl x509 -req -in "$tmpdir/csr" -signkey "$tmpdir/key" -out "$tmpdir/crt" -days "$d" -sha256 2>/dev/null; then
            DAYS="$d"
            break
        fi
    done
    rm -rf "$tmpdir"
}

# ─── Генерация ─────────────────────────────────────
gen_cert() {
    log_info "$MSG_GEN_START $NAME"
    mkdir -p "$OUTDIR"
    local KEY="$OUTDIR/$NAME.key"
    local CSR="$OUTDIR/$NAME.csr"
    local CRT="$OUTDIR/$NAME.crt"
    local PFX="$OUTDIR/$NAME.pfx"
    local SUBJ="/CN=${DESC//\//_}"
    rm -f "$KEY" "$CSR" "$CRT" "$PFX"
    if ! openssl ecparam -genkey -name prime256v1 -out "$KEY"; then
        log_error "$MSG_GEN_FAIL_KEY" "$NAME"
        return 1
    fi
    log_success "$MSG_GEN_KEY $KEY"
    if ! openssl req -new -key "$KEY" -out "$CSR" -subj "$SUBJ"; then
        log_error "$MSG_GEN_FAIL_CSR" "$NAME"
        return 1
    fi
    log_success "CSR: $CSR"
    if ! openssl x509 -req -in "$CSR" -signkey "$KEY" -out "$CRT" -days "$DAYS" -sha256; then
        log_error "$MSG_GEN_FAIL_CRT" "$NAME"
        return 1
    fi
    log_success "$MSG_GEN_CRT $CRT ($DAYS ${MSG_DAYS,,})"
    if ! openssl pkcs12 -export -out "$PFX" -inkey "$KEY" -in "$CRT" -passout pass:"$PASS"; then
        log_error "$MSG_GEN_FAIL_PFX" "$NAME"
        return 1
    fi
    rm -f "$CSR"
    log_success "PFX: $PFX"
    chmod 600 "$KEY" "$CRT" "$PFX"
}

# ─── Очистка осиротевших сертификатов ────────────
# trust_fp: короткий fingerprint (12 hex, нижний регистр) — как в `incus config trust list`
trust_fp() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null \
        | sed 's/.*=//;s/://g;' | tr 'A-F' 'a-f' | cut -c1-12
}

# incus_ui_ready: есть ли incus с incus-ui и папка сертификатов
incus_ui_ready() {
    command -v incus &>/dev/null || return 1
    dpkg -l 2>/dev/null | grep -qE "^ii.*incus-ui" || return 1
    [ -d "$OUTDIR" ] || return 1
    return 0
}

# trust_client_fps: fingerprint'ы client-сертификатов из trust store (по одному на строку)
trust_client_fps() {
    incus config trust list 2>/dev/null | tail -n +2 | awk -F'|' '
        { type=$3; fp=$5; gsub(/ /,"",type); gsub(/ /,"",fp);
          if (type=="client" && fp!="") print fp }'
}

# trust_client_names_fps: пары "имя fingerprint" client-сертификатов из trust store
# (имя = CN сертификата, как он отображается в панели)
trust_client_names_fps() {
    incus config trust list 2>/dev/null | tail -n +2 | awk -F'|' '
        { name=$2; type=$3; fp=$5; gsub(/ /,"",name); gsub(/ /,"",type); gsub(/ /,"",fp);
          if (type=="client" && fp!="") print name, fp }'
}

# Удаляет из trust store client-сертификаты с заданным именем (имя = имя файла .crt,
# как оно отображается в панели после add-certificate)
remove_trust_by_name() {
    local target="$1"
    local name fp
    while read -r name fp; do
        [ -z "$fp" ] && continue
        if [ "$name" = "$target" ]; then
            log_info "$MSG_TRUST_REMOVE_SAME" "$name"
            incus config trust remove "$fp" 2>/dev/null || true
        fi
    done < <(trust_client_names_fps)
}

cleanup_incus_trust() {
    incus_ui_ready || return

    local -A LOCAL_FPS=()
    local CRT FP
    for CRT in "$OUTDIR"/*.crt; do
        [ -f "$CRT" ] || continue
        FP=$(trust_fp "$CRT")
        [ -n "$FP" ] && LOCAL_FPS["$FP"]=1
    done

    local name base
    while read -r name FP; do
        [ -z "$FP" ] && continue
        if [ -z "${LOCAL_FPS[$FP]+x}" ]; then
            log_warning "$MSG_TRUST_REMOVE $FP"
            incus config trust remove "$FP" 2>/dev/null || true
            # сертификата нет в папке (.crt отсутствует): удаляем оставшиеся файлы, если есть.
            # .crt с этим именем тоже должен отсутствовать, иначе это файлы другого (нового) сертификата
            base="${name%.crt}"
            if [ ! -f "$OUTDIR/$base.crt" ] && { [ -f "$OUTDIR/$base.key" ] || [ -f "$OUTDIR/$base.pfx" ]; }; then
                log_info "$MSG_TRUST_REMOVE_FILES" "$base"
                rm -f "$OUTDIR/$base.key" "$OUTDIR/$base.pfx"
            fi
        fi
    done < <(trust_client_names_fps)
}

# ─── Синхронизация trust store с папкой ───────────
sync_incus_trust() {
    incus_ui_ready || return

    local -A TRUST_FPS=()
    local FP
    while IFS= read -r FP; do
        [ -z "$FP" ] && continue
        TRUST_FPS["$FP"]=1
    done < <(trust_client_fps)

    local CRT FP
    for CRT in "$OUTDIR"/*.crt; do
        [ -f "$CRT" ] || continue
        FP=$(trust_fp "$CRT")
        [ -z "$FP" ] && continue
        if [ -z "${TRUST_FPS[$FP]+x}" ]; then
            # новый сертификат: удаляем из панели старый с тем же именем файла, если есть
            remove_trust_by_name "$(basename "$CRT")"
            log_info "$MSG_TRUST_ADD $CRT"
            incus config trust add-certificate "$CRT" 2>/dev/null || true
        fi
    done
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
        # Копируем только реально сгенерированные сертификаты (с учётом пропуска занятых имён)
        local FNAME
        for FNAME in "${GENERATED_NAMES[@]}"; do
            cp "$OUTDIR/$FNAME.key" "$EXPORT_DIR/" 2>/dev/null || true
            cp "$OUTDIR/$FNAME.crt" "$EXPORT_DIR/" 2>/dev/null || true
            cp "$OUTDIR/$FNAME.pfx" "$EXPORT_DIR/" 2>/dev/null || true
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
    echo -e "${GREEN}╔═════════════════╗${NC}"
    echo -e "${GREEN}║ incus-cert v2.0 ║${NC}"
    echo -e "${GREEN}║   ECDSA + PFX   ║${NC}"
    echo -e "${GREEN}╚═════════════════╝${NC}"
    echo ""
    parse_flags "$@"

    if [ "$SERVE_ALL" -eq 1 ]; then
        export_http
        exit 0
    fi

    ask_generate

    install_deps
    if [ "$GENERATE" = "yes" ]; then
        ask_name; ask_desc; ask_password; ask_days
        if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ]; then
            log_error "$MSG_DAYS_INVALID"
            exit 1
        fi
        ask_cleanup
        if [ "$CLEANUP_ENABLE" = "yes" ]; then
            cleanup_incus_trust
        fi
        mkdir -p "$OUTDIR"
        for i in $(seq 1 "$COUNT"); do
            candidate="$BASE_NAME"
            idx=0
            while true; do
                if [ -e "$OUTDIR/${candidate}.key" ] || [ -e "$OUTDIR/${candidate}.crt" ] || [ -e "$OUTDIR/${candidate}.pfx" ]; then
                    idx=$((idx + 1))
                    candidate="${BASE_NAME}${idx}"
                else
                    break
                fi
            done
            NAME="$candidate"
            GENERATED_NAMES+=("$NAME")
            gen_cert || { log_error "Failed to generate cert $i/$COUNT"; exit 1; }
        done
        sync_incus_trust
        export_http
        if [ "$COUNT" -eq 1 ]; then
            log_success "$MSG_DONE $OUTDIR/$NAME.{key,crt,pfx}"
        else
            log_success "$MSG_DONE_MULTI $OUTDIR/$BASE_NAME*.{key,crt,pfx}"
        fi
    else
        # только синхронизация: добавляем/удаляем сертификаты по папке
        log_info "$MSG_SYNC_ONLY"
        cleanup_incus_trust
        sync_incus_trust
        log_success "$MSG_SYNC_DONE"
    fi
    echo ""
}

# ─── Оформление вывода ────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { printf "${GREEN}>>> [CERT]${NC} $1\n" "${@:2}" >&2; }
log_success() { printf "${GREEN}>>> [CERT]${NC} ✅ $1\n" "${@:2}" >&2; }
log_warning() { printf "${YELLOW}>>> [CERT]${NC} ⚠️ $1\n" "${@:2}" >&2; }
log_error() { printf "${RED}>>> [CERT]${NC} ❌ $1\n" "${@:2}" >&2; }

# ─── Локализация ─────────────────────────────────────
init_lang() {
    if [[ "$LANG" == ru_RU* ]]; then
        HELP_USAGE="incus-cert -n <имя> [-d <дни>] [-o <папка>] [-s|--serve]"
        HELP_FLAGS=" -n <имя> имя файлов (обязательно)\n -s|--serve только экспорт всей папки через HTTP"
        MSG_UNKNOWN_FLAG="Неизвестный флаг:"
        MSG_ASK_NAME="Имя файла (напр."
        MSG_ASK_DESC="Описание (напр."
        MSG_ASK_PASS="Пароль для PFX (напр."
        MSG_ASK_PASS_CONFIRM="Подтвердите пароль (Enter = пропустить): "
        MSG_PASS_MISMATCH="Пароли не совпадают, попробуйте ещё раз"
        MSG_ASK_DAYS="Срок в днях (Enter ="
        MSG_ASK_DAYS_MAX="максимум"
        MSG_ASK_CLEANUP="Зачистить из панели сертификаты, которых нет в папке? [Y/n]: "
        MSG_ASK_GENERATE="Сгенерировать сертификат? [Y/n] (exit/close/clear = отмена): "
        MSG_GEN_CANCEL="Отменено, ничего не изменено"
        MSG_GEN_INVALID="Некорректный ответ (y/n/exit/close/clear)"
        MSG_SYNC_ONLY="Синхронизация без генерации"
        MSG_SYNC_DONE="Синхронизация завершена"
        MSG_DAYS_INVALID="Некорректный срок в днях"
        MSG_ENTER_EQ_NAME="Enter = как имя"
        MSG_ENTER_NOPASS="Enter = без пароля"
        MSG_GEN_START="Генерация сертификата:"
        MSG_GEN_KEY="Ключ:"
        MSG_GEN_CRT="Сертификат:"
        MSG_GEN_FAIL_KEY="Не удалось сгенерировать ключ для %s"
        MSG_GEN_FAIL_CSR="Не удалось создать CSR для %s"
        MSG_GEN_FAIL_CRT="Не удалось подписать сертификат для %s"
        MSG_GEN_FAIL_PFX="Не удалось создать PFX для %s"
        MSG_DAYS="дней"
        MSG_TRUST_REMOVE="Удаление старого сертификата из trust store:"
        MSG_TRUST_ADD="Добавление сертификата в trust store:"
        MSG_TRUST_REMOVE_SAME="Удаление из панели сертификата с тем же именем: %s"
        MSG_TRUST_REMOVE_FILES="Удаление файлов сертификата из папки: %s"
        MSG_DONE="Готово:"
        MSG_DONE_MULTI="Готово. Сертификаты сохранены в:"
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
        HELP_USAGE="incus-cert -n <name> [-d <days>] [-o <dir>] [-s|--serve]"
        HELP_FLAGS=" -n <name> filename prefix (required)\n -s|--serve serve entire folder via HTTP"
        MSG_UNKNOWN_FLAG="Unknown flag:"
        MSG_ASK_NAME="Filename (e.g."
        MSG_ASK_DESC="Description (e.g."
        MSG_ASK_PASS="PFX password (e.g."
        MSG_ASK_PASS_CONFIRM="Confirm password (Enter = skip): "
        MSG_PASS_MISMATCH="Passwords do not match, try again"
        MSG_ASK_DAYS="Days (Enter ="
        MSG_ASK_DAYS_MAX="max"
        MSG_ASK_CLEANUP="Clean from panel certs not in folder? [Y/n]: "
        MSG_ASK_GENERATE="Generate certificate? [Y/n] (exit/close/clear = cancel): "
        MSG_GEN_CANCEL="Cancelled, nothing changed"
        MSG_GEN_INVALID="Invalid answer (y/n/exit/close/clear)"
        MSG_SYNC_ONLY="Sync only, no generation"
        MSG_SYNC_DONE="Sync complete"
        MSG_DAYS_INVALID="Invalid days value"
        MSG_ENTER_EQ_NAME="Enter = same as name"
        MSG_ENTER_NOPASS="Enter = no password"
        MSG_GEN_START="Generating certificate:"
        MSG_GEN_KEY="Key:"
        MSG_GEN_CRT="Certificate:"
        MSG_GEN_FAIL_KEY="Failed to generate key for %s"
        MSG_GEN_FAIL_CSR="Failed to create CSR for %s"
        MSG_GEN_FAIL_CRT="Failed to sign certificate for %s"
        MSG_GEN_FAIL_PFX="Failed to create PFX for %s"
        MSG_DAYS="days"
        MSG_TRUST_REMOVE="Removing old certificate from trust store:"
        MSG_TRUST_ADD="Adding certificate to trust store:"
        MSG_TRUST_REMOVE_SAME="Removing same-name cert from panel: %s"
        MSG_TRUST_REMOVE_FILES="Removing cert files from folder: %s"
        MSG_DONE="Done:"
        MSG_DONE_MULTI="Done. Certificates saved in:"
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