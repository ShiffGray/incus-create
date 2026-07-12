#!/bin/bash
#
# gen-cert v1.3
# Генерация ECDSA сертификатов + PFX
#

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}>>> [CERT]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}>>> [CERT]${NC} ✅ $1" >&2; }
log_warning() { echo -e "${YELLOW}>>> [CERT]${NC} ⚠️  $1" >&2; }
log_error()   { echo -e "${RED}>>> [CERT]${NC} ❌ $1" >&2; }

NAME=""
DESC=""
PASS=""
DAYS="36500"
OUTDIR="$HOME/.ssh"
HOSTNAME=$(hostname -s 2>/dev/null || echo "host")

# ─── Флаги ─────────────────────────────────────────
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n) NAME="$2"; shift 2 ;;
            -d) DAYS="$2"; shift 2 ;;
            -o) OUTDIR="$2"; shift 2 ;;
            --help|-h) echo "$HELP_USAGE"; echo "$HELP_FLAGS"; exit 0 ;;
            *) log_error "$MSG_UNKNOWN_FLAG $1"; exit 1 ;;
        esac
    done
}

# ─── Запрос данных ─────────────────────────────────
ask_name() {
    while [ -z "$NAME" ]; do
        read -r -p "$MSG_ASK_NAME $HOSTNAME): " NAME
    done
}

ask_desc() {
    read -r -p "$MSG_ASK_DESC ${HOSTNAME}_home, $MSG_ENTER_EQ_NAME): " DESC
    if [ -z "$DESC" ]; then DESC="$NAME"; fi
}

ask_pass() {
    read -s -p "$MSG_ASK_PASS 123456, $MSG_ENTER_NOPASS): " PASS; echo ""
}

ask_days() {
    read -r -p "$MSG_ASK_DAYS 36500): " DAYS_INPUT
    if [ -n "$DAYS_INPUT" ]; then DAYS="$DAYS_INPUT"; fi
}

# ─── Генерация ─────────────────────────────────────
gen_cert() {
    log_info "$MSG_GEN_START $NAME"
    mkdir -p "$OUTDIR"
    local KEY="$OUTDIR/$NAME.key" CSR="$OUTDIR/$NAME.csr" CRT="$OUTDIR/$NAME.crt" PFX="$OUTDIR/$NAME.pfx" SUBJ="/CN=$DESC"
    rm -f "$KEY" "$CSR" "$CRT" "$PFX"

    openssl ecparam -genkey -name prime256v1 -out "$KEY" 2>/dev/null
    log_success "$MSG_GEN_KEY $KEY"

    openssl req -new -key "$KEY" -out "$CSR" -subj "$SUBJ" 2>/dev/null
    log_success "CSR: $CSR"

    openssl x509 -req -in "$CSR" -signkey "$KEY" -out "$CRT" -days "$DAYS" -sha256 2>/dev/null
    log_success "$MSG_GEN_CRT $CRT ($DAYS ${MSG_DAYS,,})"

    openssl pkcs12 -export -out "$PFX" -inkey "$KEY" -in "$CRT" -passout pass:"$PASS" 2>/dev/null
    rm -f "$CSR"
    log_success "PFX: $PFX"
    chmod 600 "$KEY" "$CRT" "$PFX"
}

# ─── Привязка к Incus UI ──────────────────────────
bind_incus() {
    if ! command -v incus &>/dev/null; then return; fi
    if ! dpkg -l 2>/dev/null | grep -qE "^ii.*incus-ui"; then return; fi
    local CRT="$OUTDIR/$NAME.crt"
    if [ ! -f "$CRT" ]; then return; fi
    if incus config trust add-certificate "$CRT" 2>/dev/null; then
        log_success "$MSG_INCUS_OK"
    else
        log_warning "$MSG_INCUS_FAIL"
    fi
}

# ─── Главная ──────────────────────────────────────
main() {
    init_lang
    echo ""
    echo -e "${GREEN}╔══════════════════════════════╗${NC}"
    echo -e "${GREEN}║        gen-cert v1.3         ║${NC}"
    echo -e "${GREEN}║         ECDSA + PFX          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════╝${NC}"
    echo ""

    parse_flags "$@"
    ask_name; ask_desc; ask_days; ask_pass

    gen_cert
    bind_incus

    log_success "$MSG_DONE $OUTDIR/$NAME.{key,crt,pfx}"
    echo ""
}

# ══════════════════════════════════════════════════════
# ─── Локализация ─────────────────────────────────────
# ══════════════════════════════════════════════════════
init_lang() {
    if [[ "$LANG" == ru_RU* ]]; then
        HELP_USAGE="gen-cert -n <имя> [-d <дни>] [-o <папка>]"
        HELP_FLAGS="  -n <имя>      имя файлов (обязательно)"
        MSG_UNKNOWN_FLAG="Неизвестный флаг:"
        MSG_ASK_NAME="Имя файла (напр."
        MSG_ASK_DESC="Описание (напр."
        MSG_ASK_PASS="Пароль для PFX (напр."
        MSG_ASK_DAYS="Срок в днях (Enter ="
        MSG_ENTER_EQ_NAME="Enter = как имя"
        MSG_ENTER_NOPASS="Enter = без пароля"
        MSG_GEN_START="Генерация сертификата:"
        MSG_GEN_KEY="Ключ:"
        MSG_GEN_CRT="Сертификат:"
        MSG_DAYS="дней"
        MSG_INCUS_OK="Сертификат добавлен в доверенные Incus"
        MSG_INCUS_FAIL="Не удалось добавить сертификат в Incus"
        MSG_DONE="Готово:"
    else
        HELP_USAGE="gen-cert -n <name> [-d <days>] [-o <dir>]"
        HELP_FLAGS="  -n <name>     filename prefix (required)"
        MSG_UNKNOWN_FLAG="Unknown flag:"
        MSG_ASK_NAME="Filename (e.g."
        MSG_ASK_DESC="Description (e.g."
        MSG_ASK_PASS="PFX password (e.g."
        MSG_ASK_DAYS="Days (Enter ="
        MSG_ENTER_EQ_NAME="Enter = same as name"
        MSG_ENTER_NOPASS="Enter = no password"
        MSG_GEN_START="Generating certificate:"
        MSG_GEN_KEY="Key:"
        MSG_GEN_CRT="Certificate:"
        MSG_DAYS="days"
        MSG_INCUS_OK="Certificate added to Incus trusted"
        MSG_INCUS_FAIL="Failed to add certificate to Incus"
        MSG_DONE="Done:"
    fi
}

main "$@"
