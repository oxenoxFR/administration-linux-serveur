#!/usr/bin/bash
# Mission 2 — verification de la persistance apres « systemctl reboot ».
# A lancer sur srv-core, en root, apres le reboot qui suit m2-core.sh.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core
IF_NAT="${IF_NAT:-enp0s3}"

F=m2-apres-reboot.txt; : > "$CAP/$F"
titre "Persistance de la configuration reseau apres reboot"
systemctl is-system-running --wait >/dev/null 2>&1 || true
sleep 3
run $F 'uptime'
run $F 'nmcli -f NAME,DEVICE,STATE con show --active'
run $F 'cat /proc/net/bonding/bond0'
run $F 'ip -br addr'
run $F 'ip rule show'
run $F 'ip route show table transport'
run $F 'ip route get 8.8.8.8 from 10.42.42.10'
run $F 'ip route get 8.8.8.8'
run $F 'ping -c 3 10.42.0.11'
run $F 'ping -c 3 10.42.42.11'

UP=$(grep -c 'MII Status: up' /proc/net/bonding/bond0)
R1="$(ip route get 8.8.8.8 from 10.42.42.10 2>&1)"
R2="$(ip route get 8.8.8.8 2>&1)"
(( UP >= 3 )) && ok "bond0 + ses 2 ports : MII Status up" || ko "Seulement $UP lignes « MII Status: up »"
[[ $R1 == *"dev bond0.42"* ]] && ok "Regle 142 persistante (sortie bond0.42)" || ko "$R1"
[[ $R2 == *"dev $IF_NAT"* ]]  && ok "Route par defaut inchangee ($IF_NAT)"    || ko "$R2"
ping -c 2 -W 1 10.42.42.11 &>/dev/null && ok "VLAN 42 joignable" || ko "VLAN 42 injoignable"

if (( UP >= 3 )) && [[ $R1 == *"dev bond0.42"* && $R2 == *"dev $IF_NAT"* ]]; then
    valeur PERSISTANCE "toute la configuration est revenue seule apres reboot"
else
    valeur PERSISTANCE "ECHEC partiel — voir captures/m2-apres-reboot.txt"
fi
info "Suite : mission 3 -> ./m3-automatisation.sh"
