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

# incus сеть

### вот это вот базовые настройки сети
```sh
ufw allow in on incusbr0
ufw allow out on incusbr0
ufw allow in on incusbr0 to any
ufw route allow in on incusbr0
```
```sh
incus network set incusbr0 ipv4.dhcp=true
incus network set incusbr0 ipv6.dhcp.stateful=true
```
```sh
incus profile show default
```

### это ручное определение IP для контейнера вместо авто по dhcp
```sh
incus stop CONTAINER
incus config device remove CONTAINER eth0
incus config device add CONTAINER eth0 nic network=incusbr0 name=eth0 ipv4.address=IPV4ADDR ipv6.address=IPV6ADDR
incus start CONTAINER
```

# ещё приколы с файрволом
### да мне нужно было прокинуть порт в контейнер и я сделал это через панель
### но как обычно из-за ufw оно как не работало и мне помагло вот это
```sh
ufw route allow proto tcp from any to 172.24.10.2 port 12280
```
