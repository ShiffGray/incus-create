#!/bin/bash
#
# Incus Web UI Installer v2.0
# Ubuntu 20-25 | Debian 11-13
#

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Логирование
log_info()    { echo -e "${GREEN}>>> [Incus]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}>>> [Incus]${NC} ✅ $1" >&2; }
log_warning() { echo -e "${YELLOW}>>> [Incus]${NC} ⚠️  $1" >&2; }
log_error()   { echo -e "${RED}>>> [Incus]${NC} ❌ $1" >&2; }

# Неинтерактивный режим
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Глобальные переменные
OS_ID=""
OS_VERSION=""
REPO_CODENAME=""
ARCH=""

# Парсинг флагов
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                log_error "Неизвестный флаг: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# Вывод использования
print_usage() {
    echo
    echo -e "${GREEN}Использование:${NC}"
    echo "  $0              # Установить Incus + UI"
    echo "  $0 --help (-h)  # Показать эту справку"
    echo
}

# Проверка root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Требуется root (sudo)"
        exit 1
    fi
}

# Определение и проверка ОС
check_os() {
    if [ ! -f /etc/os-release ]; then
        log_error "Не удалось определить ОС"
        exit 1
    fi

    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"

    log_info "Обнаружена: $NAME $VERSION"

    case "$OS_ID" in
        debian)
            case "$OS_VERSION" in
                11|12|13)
                    REPO_CODENAME="$VERSION_CODENAME"
                    ;;
                *)
                    log_error "Поддерживается только Debian 11, 12, 13"
                    exit 1
                    ;;
            esac
            ;;
        ubuntu)
            case "$OS_VERSION" in
                20.04|22.04) REPO_CODENAME="jammy" ;;
                24.04|25.04) REPO_CODENAME="noble" ;;
                *)
                    log_error "Поддерживается только Ubuntu 20.04-25.04"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log_error "Требуется Debian или Ubuntu"
            exit 1
            ;;
    esac
}

# Проверка архитектуры
check_arch() {
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
        log_error "Требуется amd64 или arm64"
        exit 1
    fi
}

# Добавление репозитория Zabbly
add_zabbly_repo() {
    log_info "Добавление репозитория Zabbly..."

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
    log_success "Репозиторий добавлен"
}

# Установка Incus
install_incus() {
    log_info "Установка Incus..."
    apt-get install -y incus
    log_success "Incus установлен"
}

# Установка UI
install_ui() {
    log_info "Установка UI..."

    if apt-get install -y incus-ui-canonical 2>&1; then
        log_success "UI установлен"
        return 0
    fi

    log_warning "apt install не сработал, пробую установку из архива..."

    mkdir -p /tmp/incus-ui-work
    cd /tmp/incus-ui-work

    if ! curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly-ui-temp.gpg; then
        log_error "Не удалось скачать GPG ключ"
        cd /; rm -rf /tmp/incus-ui-work
        exit 1
    fi

    cat > /etc/apt/sources.list.d/zabbly-ui-temp.list <<EOF
deb [signed-by=/etc/apt/keyrings/zabbly-ui-temp.gpg] https://pkgs.zabbly.com/incus/stable noble main
EOF

    apt-get update -qq

    if ! apt-get download incus-ui-canonical 2>&1; then
        log_error "Не удалось скачать пакет incus-ui-canonical"
        cd /; rm -rf /tmp/incus-ui-work
        rm -f /etc/apt/sources.list.d/zabbly-ui-temp.list
        rm -f /etc/apt/keyrings/zabbly-ui-temp.gpg
        exit 1
    fi

    mkdir -p extract
    dpkg-deb -x incus-ui-canonical*.deb extract

    mkdir -p /opt/incus/ui

    if [ -d "extract/opt/incus/ui" ]; then
        cp -r extract/opt/incus/ui/* /opt/incus/ui/
    else
        log_error "Файлы UI не найдены в пакете"
        cd /; rm -rf /tmp/incus-ui-work
        rm -f /etc/apt/sources.list.d/zabbly-ui-temp.list
        rm -f /etc/apt/keyrings/zabbly-ui-temp.gpg
        exit 1
    fi

    cd /
    rm -rf /tmp/incus-ui-work
    rm -f /etc/apt/sources.list.d/zabbly-ui-temp.list
    rm -f /etc/apt/keyrings/zabbly-ui-temp.gpg
    apt-get update -qq

    log_success "UI установлен"
}

# Проверка установки
verify() {
    log_info "Проверка установки..."

    if ! command -v incus &>/dev/null; then
        log_error "incus не найден"
        exit 1
    fi

    log_success "Проверка завершена"
}

# Финальный вывод
print_info() {
    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}     Incus Web UI успешно установлен!     ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo "Инициализация:  incus admin init"
    echo "UI запуск:      incus webui"
    echo
}

# Cleanup при ошибке
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Ошибка установки (код: $exit_code)"
    fi
}

# ГЛАВНАЯ ФУНКЦИЯ
main() {
    trap cleanup EXIT

    # Парсим флаги ПЕРЕД всем остальным
    parse_flags "$@"

    echo
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Incus Web UI Installer v2.0       ║${NC}"
    echo -e "${GREEN}║  Ubuntu 20-25 | Debian 11-13           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo

    check_root
    check_os
    check_arch
    add_zabbly_repo
    install_incus
    install_ui
    verify
    print_info
}

main "$@"