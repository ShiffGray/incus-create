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
incus config set core.https_address=:PORT && incus config get core.https_address
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
incus stop CONTAINER
incus config device remove CONTAINER eth0
incus config device add CONTAINER eth0 nic network=incusbr0 name=eth0 ipv4.address=IPV4ADDR ipv6.address=IPV6ADDR
incus start CONTAINER
```
### ещё приколы с файрволом
### мне нужно было прокинуть порт в контейнер и я сделал это через панель
### но как обычно из-за ufw оно не работало и мне помагло вот это
```sh
ufw route allow proto tcp from any to 172.24.10.2 port 12280
```
