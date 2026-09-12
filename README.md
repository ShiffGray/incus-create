# incus-create
### это устанока и первая настройка
#### обновление и установка полезностей
```sh
apt update -y && apt upgrade -y && apt install curl sudo ufw btop tmux nano ssh unzip xz-utils -y
```
#### можно поставить русский язык
```sh
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq locales >/dev/null 2>&1 || true; sed -i 's/^# *ru_RU\.UTF-8[[:space:]]*UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen; grep -qE '^ru_RU\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen || echo 'ru_RU.UTF-8 UTF-8' >> /etc/locale.gen; locale-gen >/dev/null 2>&1 || true; update-locale LANG=ru_RU.utf8 >/dev/null 2>&1 || true; localedef --no-archive -i ru_RU -f UTF-8 /usr/lib/locale/ru_RU.utf8 >/dev/null 2>&1 || true; localedef --no-archive -i en_US -f UTF-8 /usr/lib/locale/en_US.utf8 >/dev/null 2>&1 || true; grep -q '^LOCPATH=' /etc/environment || echo 'LOCPATH=/usr/lib/locale' >> /etc/environment; grep -q '^export LOCPATH' ~/.bashrc || echo 'export LOCPATH=/usr/lib/locale LANG=ru_RU.utf8' >> ~/.bashrc; export LOCPATH=/usr/lib/locale LANG=ru_RU.utf8; locale | grep '^LANG='
```
#### генерация и настройка ssh ключа а так же смена порта
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/ssh-keys.sh)
```
#### установка и основная конфигурация самого IncusUI
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/IncusUI.sh)
```
```sh
incus admin init
```
#### генерация и настройка сертификата для IncusUI
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/incus-cert.sh)
```
#### настройка файрвола для IncusUI
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/incus-firewall.sh)
```
### ну вот это нужный мне но спорный момент с выдачей высоких привелегий и прочего прям на default профиль
#### я использую это потому что у меня во многих контейнерах крутиться VPN
```sh
incus profile set default security.privileged=true
incus profile set default linux.kernel_modules=ifb,wireguard
incus profile set default boot.autostart=true
incus profile set default security.protection.delete=true
```
```sh
incus profile show default
```
