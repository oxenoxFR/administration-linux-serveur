#!/usr/bin/bash
# Mission 2 — cote srv-edge : interface metier (10.42.0.11) + VLAN 42 (10.42.42.11).
# A lancer sur srv-edge, en root, AVANT m2-core.sh. Relancable.
# Si ton interface helios-lan ne s'appelle pas enp0s9 :  IF_EDGE=enp0sX ./m2-edge.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-edge

IF_EDGE="${IF_EDGE:-enp0s9}"
F=m2-edge.txt; : > "$CAP/$F"

titre "Interfaces de srv-edge"
run $F 'ip -br link'
ip link show "$IF_EDGE" &>/dev/null || { ko "Interface $IF_EDGE introuvable. Relance avec : IF_EDGE=<nom> $0"; exit 1; }

titre "2.1 — Connexion metier sur $IF_EDGE"
nm_supprimer vlan42
nm_supprimer metier
nm_neutraliser "$IF_EDGE" metier
run $F "nmcli con add type ethernet con-name metier ifname $IF_EDGE \
  ipv4.method manual ipv4.addresses 10.42.0.11/24 ipv4.never-default yes ipv6.method disabled"
run $F "nmcli con up metier"

titre "2.3 — VLAN 42 « transport »"
run $F "nmcli con add type vlan con-name vlan42 ifname $IF_EDGE.42 dev $IF_EDGE id 42 \
  ipv4.method manual ipv4.addresses 10.42.42.11/24 ipv4.never-default yes ipv6.method disabled"
run $F "nmcli con up vlan42"
run $F 'ip -br addr'

ok "srv-edge pret. Lance maintenant m2-core.sh sur srv-core."
