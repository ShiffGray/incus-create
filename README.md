# incus-create
```sh
apt update -y && apt upgrade -y && apt install curl sudo ufw btop tmux -y
```
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/IncusUI.sh)
```
```sh
incus admin init
```
```sh
incus config set core.https_address=:24550 && incus config get core.https_address
```
```sh
systemctl restart incus
```
```sh
incus profile set default security.privileged=true
incus profile set default linux.kernel_modules=ifb,wireguard
incus profile set default boot.autostart=true
incus profile set default security.protection.delete=true
ufw allow in on incusbr0
ufw allow out on incusbr0
incus network set incusbr0 ipv4.dhcp=true
incus network set incusbr0 ipv6.dhcp.stateful=true
```
