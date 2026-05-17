# incus-create
### это устанока и первая настройка
```sh
apt update -y && apt upgrade -y && apt install curl sudo ufw btop tmux nano ssh -y
```
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/IncusUI.sh)
```
```sh
incus admin init
```
```sh
incus config set core.https_address=:ПОРТ && incus config get core.https_address
```
```sh
systemctl restart incus
```
```sh
incus list
```
### ну вот это нужный мне но спорный момент с выдачей высоких привелегий и прочего прям на default профиль
```sh
incus profile set default security.privileged=true
incus profile set default linux.kernel_modules=ifb,wireguard
incus profile set default boot.autostart=true
incus profile set default security.protection.delete=true
```
```sh
incus profile show default
```

# incus сеть
```sh
sudo modprobe br_netfilter && echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
```
### если используеться ufw то надо добавить разрешения на локальный сетевой мост контейнеров
```sh
ufw allow in on incusbr0
ufw allow out on incusbr0
ufw allow in on incusbr0 to any
ufw route allow in on incusbr0
```
### ну и ещё можно dhcp включить потому что иначе адресы не будут выдаваться автоматически
```sh
incus network set incusbr0 ipv4.dhcp=true
incus network set incusbr0 ipv6.dhcp.stateful=true
```
### но кстати можно и вручную прописать конкретные адреса контейнерам вот так
```sh
incus stop ИМЯ_КОНТЕЙНЕРА
incus config device remove ИМЯ_КОНТЕЙНЕРА eth0
incus config device add ИМЯ_КОНТЕЙНЕРА eth0 nic network=incusbr0 name=eth0 ipv4.address=IPАДРЕСV4 ipv6.address=IPАДРЕСV6
incus start ИМЯ_КОНТЕЙНЕРА
```
### ещё приколы с файрволом
### мне нужно было прокинуть порт в контейнер и я сделал это через панель
### но как обычно из-за ufw оно не работало и мне помагло вот это
```sh
ufw route allow proto ПРОТОКОЛ from any to IP_КОНТЕЙНЕРА port ПОРТ
```

# я вообще кстати собираюсь наверное использовать этот репозиторий под свои записки так что да это нормально то что тут дальше будут не связанные с incusui инструкции и прочее
### имя хоста можно сменить вот так
```sh
sudo hostnamectl set-hostname НОВОЕ_ИМЯ
```
#### но только плюс было бы не плохо так же проверить и отредактировать
```sh
sudo nano /etc/hosts
```

### сгенерировать и засунуть в incus ssl сертификат
```sh
gen_cert() {
	openssl ecparam -genkey -name prime256v1 -out "$NAME.key"
	openssl req -new -key "$NAME.key" -out "$NAME.csr" -subj "$SUBJ"
	openssl x509 -req -in "$NAME.csr" -signkey "$NAME.key" -out "$NAME.crt" -days "$DAYS" -sha256
	openssl pkcs12 -export -out "$NAME.pfx" -inkey "$NAME.key" -in "$NAME.crt" -passout pass:"$PASS"
	incus config trust add-certificate $NAME.crt
}
NAME="ИМЯ"
SUBJ="/CN=ХОСТИНГ_СТРАНА-НОМЕР_ИМЯ"
DAYS="36500"
PASS="ПАРОЛЬ"
gen_cert
```
#### Ну и потому можно добавить в incus этот сертификат, а так же удалить его по fingerprint
```sh
incus config trust add-certificate ИМЯ.crt
incus config trust list
incus config trust remove FINGERPRINT
```

### сгенерировать ssh ключ
```sh
ssh-keygen -t ed25519 -b 5120 -f ПУТЬ/ИМЯ -N ПАРОЛЬ_КЛЮЧА -a 480 -q
```

### включить пролистывание в tmux сессиях
```sh
echo "set -g mouse on" >> ~/.tmux.conf && tmux source-file ~/.tmux.conf
```
