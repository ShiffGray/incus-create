#!/bin/bash
#
# Incus Web UI Installer v2.3
# Ubuntu 20-26 | Debian 11-13
#

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()    { echo -e "${GREEN}>>> [Incus]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}>>> [Incus]${NC} ✅ $1" >&2; }
log_warning() { echo -e "${YELLOW}>>> [Incus]${NC} ⚠️  $1" >&2; }
log_error()   { echo -e "${RED}>>> [Incus]${NC} ❌ $1" >&2; }

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

OS_ID=""; OS_VERSION=""; REPO_CODENAME=""; ARCH=""

# ─── Флаги ─────────────────────────────────────────
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case $1 in --help|-h) echo "$HELP_USAGE"; echo "$HELP_NOFLAGS"; exit 0 ;;
        *) log_error "$MSG_UNKNOWN_FLAG $1"; exit 1 ;; esac
    done
}

# ─── Проверка root ─────────────────────────────────
check_root() { if [ "$EUID" -ne 0 ]; then log_error "$MSG_NO_ROOT"; exit 1; fi; }

# ─── Определение ОС ────────────────────────────────
check_os() {
    if [ ! -f /etc/os-release ]; then log_error "$MSG_NO_OS"; exit 1; fi
    . /etc/os-release
    OS_ID="$ID"; OS_VERSION="$VERSION_ID"
    log_info "$MSG_DETECTED $NAME $VERSION"

    case "$OS_ID" in
        debian)
            case "$OS_VERSION" in 11|12|13) REPO_CODENAME="$VERSION_CODENAME" ;;
            *) log_error "$MSG_DEB_ONLY"; exit 1 ;; esac ;;
        ubuntu)
            case "$OS_VERSION" in
                20.04|22.04) REPO_CODENAME="jammy" ;;
                24.04|25.04|25.10|26.04) REPO_CODENAME="noble" ;;
                *) log_error "$MSG_UBU_ONLY"; exit 1 ;; esac ;;
        *) log_error "$MSG_OS_ONLY"; exit 1 ;;
    esac

    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
        log_error "$MSG_ARCH_UNSUP"; exit 1
    fi
}

# ─── Репозиторий Zabbly ────────────────────────────
add_zabbly_repo() {
    log_info "$MSG_REPO_ADD"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
    cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${REPO_CODENAME}
Components: main
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
    apt-get update -qq
    log_success "$MSG_REPO_OK"
}

# ─── Установка Incus ───────────────────────────────
install_incus() {
    log_info "$MSG_INSTALL_INCUS"
    apt-get install -y incus
    log_success "$MSG_INCUS_OK"
}

# ─── Установка UI ──────────────────────────────────
install_ui() {
    log_info "$MSG_INSTALL_UI"

    if apt-get install -y incus-ui-canonical 2>&1; then
        log_success "$MSG_UI_OK"
        return 0
    fi

    log_warning "$MSG_UI_FALLBACK"
    local TMPD="/tmp/incus-ui-work"
    mkdir -p "$TMPD" && cd "$TMPD"

    curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly-ui-temp.gpg || {
        log_error "$MSG_UI_NO_GPG"; cd /; rm -rf "$TMPD"; exit 1
    }

    cat > /etc/apt/sources.list.d/zabbly-ui-temp.list <<EOF
deb [signed-by=/etc/apt/keyrings/zabbly-ui-temp.gpg] https://pkgs.zabbly.com/incus/stable noble main
EOF

    apt-get update -qq

    if ! apt-get download incus-ui-canonical 2>&1; then
        log_error "$MSG_UI_NO_PKG"
        cd /; rm -rf "$TMPD"
        rm -f /etc/apt/sources.list.d/zabbly-ui-temp.list /etc/apt/keyrings/zabbly-ui-temp.gpg
        exit 1
    fi

    mkdir -p extract
    dpkg-deb -x incus-ui-canonical*.deb extract

    if [ -d "extract/opt/incus/ui" ]; then
        mkdir -p /opt/incus/ui
        cp -r extract/opt/incus/ui/* /opt/incus/ui/
        log_success "$MSG_UI_OK"
    else
        log_error "$MSG_UI_NO_FILES"
        cd /; rm -rf "$TMPD"
        rm -f /etc/apt/sources.list.d/zabbly-ui-temp.list /etc/apt/keyrings/zabbly-ui-temp.gpg
        exit 1
    fi

    cd /; rm -rf "$TMPD"
    rm -f /etc/apt/sources.list.d/zabbly-ui-temp.list /etc/apt/keyrings/zabbly-ui-temp.gpg
    apt-get update -qq
}

# ─── Проверка ──────────────────────────────────────
verify() {
    log_info "$MSG_VERIFY"
    if ! command -v incus &>/dev/null; then log_error "$MSG_INCUS_MISSING"; exit 1; fi
    log_success "$MSG_VERIFY_OK"
}

# ─── Финальный вывод ──────────────────────────────
print_info() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}     $MSG_FINISHED     ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "$MSG_INIT:  incus admin init"
    echo "$MSG_LAUNCH: incus webui"
    echo ""
}

# ─── Cleanup ──────────────────────────────────────
cleanup() { local rc=$?; if [ $rc -ne 0 ]; then log_error "$MSG_ERROR $rc"; fi; }

# ─── Главная ──────────────────────────────────────
main() {
    init_lang
    trap cleanup EXIT
    parse_flags "$@"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Incus Web UI Installer v2.3        ║${NC}"
    echo -e "${GREEN}║     Ubuntu 20-26 | Debian 11-13        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""

    check_root; check_os
    add_zabbly_repo; install_incus; install_ui
    verify; print_info
}

# ══════════════════════════════════════════════════════
# ─── Локализация ─────────────────────────────────────
# ══════════════════════════════════════════════════════
init_lang() {
    if [[ "$LANG" == ru_RU* ]]; then
        HELP_USAGE="Использование: $0"
        HELP_NOFLAGS="  Устанавливает Incus + IncusUI"
        MSG_UNKNOWN_FLAG="Неизвестный флаг:"
        MSG_NO_ROOT="Требуется root (sudo)"
        MSG_NO_OS="Не удалось определить ОС"
        MSG_DETECTED="Обнаружена:"
        MSG_DEB_ONLY="Поддерживается только Debian 11, 12, 13"
        MSG_UBU_ONLY="Поддерживается только Ubuntu 20.04-26.04"
        MSG_OS_ONLY="Требуется Debian или Ubuntu"
        MSG_ARCH_UNSUP="Требуется amd64 или arm64"
        MSG_REPO_ADD="Добавление репозитория Zabbly..."
        MSG_REPO_OK="Репозиторий добавлен"
        MSG_INSTALL_INCUS="Установка Incus..."
        MSG_INCUS_OK="Incus установлен"
        MSG_INSTALL_UI="Установка UI..."
        MSG_UI_OK="UI установлен"
        MSG_UI_FALLBACK="apt install не сработал, пробую установку из архива..."
        MSG_UI_NO_GPG="Не удалось скачать GPG ключ"
        MSG_UI_NO_PKG="Не удалось скачать пакет incus-ui-canonical"
        MSG_UI_NO_FILES="Файлы UI не найдены в пакете"
        MSG_VERIFY="Проверка установки..."
        MSG_INCUS_MISSING="incus не найден"
        MSG_VERIFY_OK="Проверка завершена"
        MSG_FINISHED="Incus Web UI успешно установлен!"
        MSG_INIT="Инициализация"
        MSG_LAUNCH="UI запуск"
        MSG_ERROR="Ошибка установки (код:"
    else
        HELP_USAGE="Usage: $0"
        HELP_NOFLAGS="  Installs Incus + IncusUI"
        MSG_UNKNOWN_FLAG="Unknown flag:"
        MSG_NO_ROOT="Root required (sudo)"
        MSG_NO_OS="Failed to detect OS"
        MSG_DETECTED="Detected:"
        MSG_DEB_ONLY="Only Debian 11, 12, 13 supported"
        MSG_UBU_ONLY="Only Ubuntu 20.04-26.04 supported"
        MSG_OS_ONLY="Debian or Ubuntu required"
        MSG_ARCH_UNSUP="Only amd64 or arm64 supported"
        MSG_REPO_ADD="Adding Zabbly repository..."
        MSG_REPO_OK="Repository added"
        MSG_INSTALL_INCUS="Installing Incus..."
        MSG_INCUS_OK="Incus installed"
        MSG_INSTALL_UI="Installing UI..."
        MSG_UI_OK="UI installed"
        MSG_UI_FALLBACK="apt install failed, trying archive install..."
        MSG_UI_NO_GPG="Failed to download GPG key"
        MSG_UI_NO_PKG="Failed to download incus-ui-canonical package"
        MSG_UI_NO_FILES="UI files not found in package"
        MSG_VERIFY="Verifying installation..."
        MSG_INCUS_MISSING="incus not found"
        MSG_VERIFY_OK="Verification complete"
        MSG_FINISHED="Incus Web UI successfully installed!"
        MSG_INIT="Initialize"
        MSG_LAUNCH="Launch UI"
        MSG_ERROR="Installation error (code:"
    fi
}

main "$@"
