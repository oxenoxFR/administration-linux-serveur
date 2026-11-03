#!/usr/bin/bash
# Mission 1.1 (partie 1) — mesurer le demarrage AVANT allegement, puis alleger.
# A lancer sur srv-core, en root. Ensuite : reboot, puis m1b-services.sh
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core

F=m1-boot-avant.txt; : > "$CAP/$F"

titre "1.1 — Mesure du demarrage (avant)"
info "Attente de la fin complete du demarrage..."
systemctl is-system-running --wait >/dev/null 2>&1 || true
run $F 'systemd-analyze'
run $F 'systemd-analyze blame | head -15'
run $F 'systemd-analyze critical-chain'
systemd-analyze plot > "$CAP/boot-avant.svg" && cp "$CAP/boot-avant.svg" /root/boot-avant.svg
ok "Graphe enregistre : captures/boot-avant.svg (copie dans /root/boot-avant.svg)"

valeur BOOT_AVANT  "$(systemd-analyze | grep -m1 -o '= .*' | cut -c3-)"
valeur BLAME_AVANT "$(systemd-analyze blame | head -3 | awk '{$1=$1};1' | paste -sd ',' | sed 's/,/, /g')"

titre "1.1 — Allegement"
run $F 'systemctl disable --now firewalld'
run $F 'systemctl mask NetworkManager-wait-online.service'
run $F 'systemctl is-enabled firewalld NetworkManager-wait-online.service'

echo
info "Il faut redemarrer pour mesurer l'effet. Apres le reboot, lance :  ./m1b-services.sh"
confirmer "Redemarrer srv-core maintenant ?" && systemctl reboot
