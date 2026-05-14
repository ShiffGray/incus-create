# incus-create
```sh
apt update -y && apt upgrade -y && apt install curl sudo ufw btop tmux -y
```
```sh
bash <(curl -sSL https://raw.githubusercontent.com/ShiffGray/incus-create/refs/heads/main/IncusUI.sh)
```
```sh
incus config set core.https_address=:24550 && incus config get core.https_address
```
```sh
systemctl restart incus
```
