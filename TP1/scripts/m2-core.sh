#!/usr/bin/bash
# Mission 2 — cote srv-core : bond active-backup, bascule, VLAN 42, routage par regles.
# A lancer sur srv-core, en root, APRES m2-edge.sh sur srv-edge. Relancable.
# Noms d'interfaces differents ?  P1=enp0sX P2=enp0sY IF_NAT=enp0sZ ./m2-core.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core

P1="${P1:-enp0s9}"      # carte 3 VirtualBox (primary)
P2="${P2:-enp0s10}"     # carte 4 VirtualBox
IF_NAT="${IF_NAT:-enp0s3}"

# ===================== 2.1 — bond active-backup =====================
F=m2-bond.txt; : > "$CAP/$F"
titre "2.1 — Interfaces disponibles"
run $F 'ip -br link'
for i in "$P1" "$P2"; do
    ip link show "$i" &>/dev/null || { ko "Interface $i introuvable. Relance avec P1=... P2=... $0"; exit 1; }
done

titre "2.1 — Agregation active-backup ($P1 primaire + $P2)"
for c in bond0.42 bond0-p1 bond0-p2 bond0; do nm_supprimer "$c"; done
nm_neutraliser "$P1" bond0-p1
nm_neutraliser "$P2" bond0-p2
run $F "nmcli con add type bond con-name bond0 ifname bond0 \
  bond.options 'mode=active-backup,miimon=100,primary=$P1,fail_over_mac=active' \
  ipv4.method manual ipv4.addresses 10.42.0.10/24 ipv4.never-default yes ipv6.method disabled"
run $F "nmcli con add type ethernet con-name bond0-p1 ifname $P1 master bond0"
run $F "nmcli con add type ethernet con-name bond0-p2 ifname $P2 master bond0"
run $F "nmcli con up bond0 ; nmcli con up bond0-p1 ; nmcli con up bond0-p2"
sleep 2
run $F 'cat /proc/net/bonding/bond0'
run $F 'ip -d link show bond0'

if ! ping -c 3 -W 1 10.42.0.11 &>/dev/null; then
    ko "srv-edge (10.42.0.11) ne repond pas."
    info "As-tu lance m2-edge.sh sur srv-edge ? Les cartes 3 et 4 de srv-core et la carte de srv-edge sont-elles sur le reseau interne « helios-lan » ?"
    confirmer "Continuer quand meme ?" || exit 1
else
    ok "srv-edge joignable via le bond"
fi

# ===================== 2.2 — bascule =====================
F=m2-bascule.txt; : > "$CAP/$F"
PINGF="$CAP/m2-bascule-ping.txt"
titre "2.2 — Provoquer la bascule"
marque $F "AVANT la coupure"
run $F 'cat /proc/net/bonding/bond0'

# -D horodatage, -O signale chaque requete restee sans reponse ; stdbuf force l'ecriture ligne par ligne
stdbuf -oL ping -D -O 10.42.0.11 > "$PINGF" 2>&1 &
PINGPID=$!
sleep 3
pause "Sur ton PC HOTE, lance :  hote-bascule.bat off    (coupe la carte 3 = $P1)"
sleep 3
marque $F "PENDANT la coupure"
run $F "grep -E 'Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0"
ACTIF_PENDANT="$(awk -F': ' '/Currently Active Slave/ {print $2}' /proc/net/bonding/bond0)"
run $F "journalctl -k -n 20 --no-pager | grep -i bond"
pause "Retablis le lien sur l'hote :  hote-bascule.bat on"
sleep 5
marque $F "APRES retablissement"
run $F "grep -E 'Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0"
run $F "journalctl -k -n 10 --no-pager | grep -i bond"
sleep 2
kill -INT "$PINGPID" 2>/dev/null; sleep 1; kill "$PINGPID" 2>/dev/null; wait "$PINGPID" 2>/dev/null

RECUS=$(grep -c 'bytes from' "$PINGF")
PERDUS=$(grep -c 'no answer yet' "$PINGF")
{ echo; echo "### Bilan : $RECUS reponses, $PERDUS requete(s) sans reponse"; } | tee -a "$PINGF"
valeur PING_PERTES "$PERDUS requete(s) perdue(s) sur $((RECUS + PERDUS))"
valeur ACTIF_PENDANT "$ACTIF_PENDANT"
if (( PERDUS <= 2 )); then ok "Bascule : $PERDUS requete(s) perdue(s) (<= 2)"
else ko "Bascule : $PERDUS requetes perdues (> 2) — refais le test, attends bien la fin de chaque etape"; fi

# ===================== 2.3 — VLAN 42 =====================
F=m2-vlan.txt; : > "$CAP/$F"
titre "2.3 — Sous-interface VLAN 802.1Q « transport » (id 42)"
run $F "nmcli con add type vlan con-name bond0.42 ifname bond0.42 dev bond0 id 42 \
  ipv4.method manual ipv4.addresses 10.42.42.10/24 ipv4.never-default yes ipv6.method disabled"
run $F "nmcli con up bond0.42"
run $F "ip -d link show bond0.42 | grep -A1 vlan"
rpm -q tcpdump &>/dev/null || run $F "dnf -y install tcpdump"

titre "2.3 — Preuve du marquage 802.1Q (tcpdump)"
timeout 25 tcpdump -nei bond0 -c 5 -w "$CAP/vlan42.pcap" 'vlan 42' 2>/dev/null &
TPID=$!
sleep 2
run $F "ping -c 5 10.42.42.11"
wait "$TPID" 2>/dev/null
run m2-tcpdump-vlan42.txt "tcpdump -nner $CAP/vlan42.pcap"
if tcpdump -nner "$CAP/vlan42.pcap" 2>/dev/null | grep -q 'vlan 42'; then
    ok "Trames etiquetees « vlan 42 » capturees (captures/m2-tcpdump-vlan42.txt + vlan42.pcap)"
else
    ko "Aucune trame vlan 42 capturee — vlan42 est-il actif sur srv-edge ?"
fi

# ===================== 2.4 — routage par regles =====================
F=m2-routage.txt; : > "$CAP/$F"
titre "2.4 — Table de routage secondaire « transport » (142)"
if [[ -f /etc/iproute2/rt_tables ]]; then
    grep -qs '^142' /etc/iproute2/rt_tables || echo '142 transport' >> /etc/iproute2/rt_tables
else   # iproute2 recent : le fichier par defaut vit dans /usr/share, on ajoute un fragment
    install -d /etc/iproute2/rt_tables.d
    echo '142 transport' > /etc/iproute2/rt_tables.d/transport.conf
fi
run $F "grep -rh transport /etc/iproute2/"
run $F "nmcli con mod bond0.42 \
  +ipv4.routes '0.0.0.0/0 10.42.42.11 table=142' \
  +ipv4.routing-rules 'priority 100 from 10.42.42.10/32 table 142'"
run $F "nmcli con up bond0.42"
sleep 1
run $F 'ip rule show'
run $F 'ip route show table transport'
run $F 'ip route get 8.8.8.8 from 10.42.42.10'
run $F 'ip route get 8.8.8.8'
R1="$(ip route get 8.8.8.8 from 10.42.42.10 2>&1)"
R2="$(ip route get 8.8.8.8 2>&1)"
[[ $R1 == *"dev bond0.42"* ]] && ok "Depuis 10.42.42.10 -> sortie par bond0.42" || ko "Depuis 10.42.42.10 : $R1"
[[ $R2 == *"dev $IF_NAT"* ]]  && ok "Trafic normal -> sortie par $IF_NAT"     || ko "Trafic normal : $R2"

nmcli -f all con show bond0 > "$CFG/bond0.txt"
ok "configs/bond0.txt genere (nmcli -f all con show bond0)"

echo
info "Derniere etape : prouver la persistance. Apres le reboot, lance :  ./m2-verif-reboot.sh"
confirmer "Redemarrer srv-core maintenant ?" && systemctl reboot
