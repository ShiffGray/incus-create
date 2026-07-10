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
            --help|-h)
                echo "gen-cert -n <имя> [-d <дни>] [-o <папка>]"
                echo "  -n <имя>      имя файлов (обязательно)"
                echo "  -d <дни>       срок (по умолч. 36500)"
                echo "  -o <папка>     куда сохранить (по умолч. ~/.ssh/)"
                exit 0 ;;
            *) log_error "Неизвестный флаг: $1"; exit 1 ;;
        esac
    done
}

# ─── Запрос данных ─────────────────────────────────
ask_name() {
    while [ -z "$NAME" ]; do
        read -r -p "Имя файла (напр. $HOSTNAME): " NAME
    done
}

ask_desc() {
    read -r -p "Описание (напр. ${HOSTNAME}_home, Enter = как имя): " DESC
    if [ -z "$DESC" ]; then
        DESC="$NAME"
    fi
}

ask_pass() {
    read -s -p "Пароль для PFX (напр. 123456, Enter = без пароля): " PASS
    echo ""
}

ask_days() {
    read -r -p "Срок в днях (Enter = 36500): " DAYS_INPUT
    if [ -n "$DAYS_INPUT" ]; then
        DAYS="$DAYS_INPUT"
    fi
}

# ─── Генерация ─────────────────────────────────────
gen_cert() {
    log_info "Генерация сертификата: $NAME"

    mkdir -p "$OUTDIR"

    local KEY="$OUTDIR/$NAME.key"
    local CSR="$OUTDIR/$NAME.csr"
    local CRT="$OUTDIR/$NAME.crt"
    local PFX="$OUTDIR/$NAME.pfx"
    local SUBJ="/CN=$DESC"

    rm -f "$KEY" "$CSR" "$CRT" "$PFX"

    # ECDSA P-256 ключ
    openssl ecparam -genkey -name prime256v1 -out "$KEY" 2>/dev/null
    log_success "Ключ: $KEY"

    # Запрос (CSR)
    openssl req -new -key "$KEY" -out "$CSR" -subj "$SUBJ" 2>/dev/null
    log_success "CSR: $CSR"

    # Подписанный сертификат
    openssl x509 -req -in "$CSR" -signkey "$KEY" -out "$CRT" -days "$DAYS" -sha256 2>/dev/null
    log_success "Сертификат: $CRT ($DAYS дней)"

    # PFX
    openssl pkcs12 -export -out "$PFX" -inkey "$KEY" -in "$CRT" -passout pass:"$PASS" 2>/dev/null
    rm -f "$CSR"
    log_success "PFX: $PFX"

    chmod 600 "$KEY" "$CRT" "$PFX"
}

# ─── Привязка к Incus UI ──────────────────────────
bind_incus() {
    if ! command -v incus &>/dev/null; then return; fi
    # Проверяем что UI установлен (incus-ui-canonical или incus-ui)
    if ! dpkg -l 2>/dev/null | grep -qE "^ii.*incus-ui"; then return; fi
    local CRT="$OUTDIR/$NAME.crt"
    if [ ! -f "$CRT" ]; then return; fi
    if incus config trust add-certificate "$CRT" 2>/dev/null; then
        log_success "Сертификат добавлен в доверенные Incus"
    else
        log_warning "Не удалось добавить сертификат в Incus"
    fi
}

# ─── Главная ──────────────────────────────────────
main() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════╗${NC}"
    echo -e "${GREEN}║        gen-cert v1.3         ║${NC}"
    echo -e "${GREEN}║         ECDSA + PFX          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════╝${NC}"
    echo ""

    parse_flags "$@"
    ask_name
    ask_desc
    ask_days
    ask_pass

    gen_cert
    bind_incus

    log_success "Готово: $OUTDIR/$NAME.{key,crt,pfx}"
    echo ""
}

main "$@"
