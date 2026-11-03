#!/usr/bin/bash
# Missions 1.1 (fin) a 1.4 — mesure apres reboot, service de collecte, kill -9,
# drop-in, durcissement, target metier, priorites de processus.
# A lancer sur srv-core, en root, APRES m1a-boot-avant.sh + reboot. Relancable.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core

SVC=helios-collect.service
DROPIN=/etc/systemd/system/$SVC.d
CSV=/var/lib/helios/telemetry.csv

# ===================== 1.1 (fin) — demarrage apres allegement =====================
F=m1-boot-apres.txt; : > "$CAP/$F"
titre "1.1 — Mesure du demarrage (apres allegement)"
systemctl is-system-running --wait >/dev/null 2>&1 || true
run $F 'systemd-analyze'
run $F 'systemd-analyze blame | head -15'
run $F 'systemd-analyze critical-chain'
systemd-analyze plot > "$CAP/boot-apres.svg" && cp "$CAP/boot-apres.svg" /root/boot-apres.svg
ok "Graphe enregistre : captures/boot-apres.svg"
valeur BOOT_APRES  "$(systemd-analyze | grep -m1 -o '= .*' | cut -c3-)"
valeur BLAME_APRES "$(systemd-analyze blame | head -3 | awk '{$1=$1};1' | paste -sd ',' | sed 's/,/, /g')"

# ===================== 1.2 — service de collecte =====================
F=m1-service.txt; : > "$CAP/$F"
titre "1.2 — Installation du service de collecte"
install -d -m 0755 /usr/local/sbin /var/lib/helios /var/log/helios
install -m 0755 "$CFG/helios-collect.sh" /usr/local/sbin/helios-collect.sh
bash -n /usr/local/sbin/helios-collect.sh && ok "Syntaxe de helios-collect.sh OK (bash -n)"
if ! id helios &>/dev/null; then
    useradd --system --shell /sbin/nologin --home-dir /var/lib/helios helios && ok "Compte systeme helios cree"
fi
chown -R helios:helios /var/lib/helios /var/log/helios

rm -rf "$DROPIN"   # on repart de l'unit nue pour mesurer le score « avant »
install -m 0644 "$CFG/helios-collect.service" /etc/systemd/system/$SVC
run $F "systemd-analyze verify /etc/systemd/system/$SVC"
systemctl daemon-reload
run $F "systemctl enable $SVC && systemctl restart $SVC"
sleep 2
run $F "systemctl status $SVC --no-pager | head -12"
run $F "id helios && ls -l /var/lib/helios"

F=m1-security.txt; : > "$CAP/$F"
titre "1.2 — Score d'exposition AVANT durcissement"
marque $F "AVANT durcissement (unit d'origine seule)"
run $F "systemd-analyze security $SVC --no-pager"
valeur SCORE_AVANT "$(systemd-analyze security $SVC --no-pager 2>/dev/null | grep -o 'exposure level for .*' | sed 's/.*: //')"

# ===================== 1.3 — redemarrage automatique =====================
F=m1-restart.txt; : > "$CAP/$F"
titre "1.3 — Preuve du redemarrage automatique (kill -9)"
P1="$(systemctl show -p MainPID --value $SVC)"
run $F "systemctl show -p MainPID -p NRestarts $SVC"
run $F "kill -9 $P1"
info "Attente 8 s (RestartSec=5s)..."
sleep 8
run $F "systemctl status $SVC --no-pager | head -5"
run $F "systemctl show -p MainPID -p NRestarts $SVC"
run $F "journalctl -u $SVC -n 8 --no-pager"
P2="$(systemctl show -p MainPID --value $SVC)"
if systemctl is-active -q $SVC && [[ $P2 != "$P1" && $P2 != 0 ]]; then
    ok "Le service a survecu au kill -9 (PID $P1 -> $P2)"
    valeur KILL9 "relance automatiquement environ 5 s apres le kill -9 (PID $P1 -> $P2)"
else
    ko "Le service n'a pas redemarre — regarde journalctl -u $SVC"
    valeur KILL9 "ECHEC : le service n'a pas redemarre"
fi

titre "1.3 — Surcharge par drop-in (override.conf)"
marque $F "Drop-in override.conf"
install -d -m 0755 "$DROPIN"
install -m 0644 "$CFG/override.conf" "$DROPIN/override.conf"
info "Equivalent exact de « systemctl edit $SVC » : meme fichier, sans editeur interactif."
systemctl daemon-reload
run $F "systemctl cat $SVC"
run $F "systemctl restart $SVC"
run $F "systemctl show -p CPUQuotaPerSecUSec -p MemoryMax -p Nice -p IOWeight -p Environment $SVC"
MM="$(systemctl show -p MemoryMax --value $SVC)"
if [[ $MM == 100663296 ]]; then
    ok "MemoryMax = 100663296 (96 Mio) sans toucher a l'unit d'origine"
else
    ko "MemoryMax = $MM (attendu 100663296)"
fi
valeur MEMORYMAX "$MM"
run $F "systemd-cgls --no-pager /system.slice/$SVC"
run $F "systemd-cgtop -b --iterations=3"

sleep 1
L1=$(wc -l < "$CSV"); sleep 11; L2=$(wc -l < "$CSV")
info "Lignes ajoutees en 11 s : $((L2 - L1)) (attendu ~2 avec HELIOS_INTERVAL=5)"
valeur INTERVALLE "$((L2 - L1)) lignes ecrites en 11 s"
run $F "ps -o pid,ni,comm -p \$(systemctl show -p MainPID --value $SVC)"

# ===================== 1.3 bis — durcissement =====================
F=m1-security.txt
titre "1.3 — Durcissement (drop-in hardening.conf) puis score APRES"
install -m 0644 "$CFG/hardening.conf" "$DROPIN/hardening.conf"
systemctl daemon-reload
run $F "systemd-analyze verify /etc/systemd/system/$SVC"
systemctl restart $SVC; sleep 3
L1=$(wc -l < "$CSV"); sleep 6; L2=$(wc -l < "$CSV")
if systemctl is-active -q $SVC && (( L2 > L1 )); then
    ok "Le service tourne toujours et ecrit dans $CSV apres durcissement"
else
    ko "Le durcissement casse le service -> retour arriere automatique"
    journalctl -u $SVC -n 15 --no-pager | tee -a "$CAP/$F"
    rm -f "$DROPIN/hardening.conf"; systemctl daemon-reload; systemctl restart $SVC
fi
marque $F "APRES durcissement (override.conf + hardening.conf)"
run $F "systemd-analyze security $SVC --no-pager"
valeur SCORE_APRES "$(systemd-analyze security $SVC --no-pager 2>/dev/null | grep -o 'exposure level for .*' | sed 's/.*: //')"

# ===================== 1.4 — target metier =====================
F=m1-target.txt; : > "$CAP/$F"
titre "1.4 — Target metier helios.target"
install -m 0644 "$CFG/helios.target" /etc/systemd/system/helios.target
run $F "systemd-analyze verify /etc/systemd/system/helios.target"
systemctl daemon-reload
run $F "systemctl add-wants helios.target $SVC"
run $F "systemctl enable helios.target"
run $F "systemctl list-dependencies helios.target --no-pager"
if systemctl list-dependencies helios.target --no-pager | grep -q "$SVC"; then
    ok "helios.target tire bien $SVC"
else
    ko "$SVC absent de list-dependencies helios.target"
fi
marque $F "Arret de la target"
run $F "systemctl stop helios.target"
run $F "systemctl is-active helios.target $SVC"
valeur TARGET_STOP "$(systemctl is-active $SVC)"
marque $F "Redemarrage de la target"
run $F "systemctl start helios.target"
run $F "systemctl is-active helios.target $SVC"

# ===================== 1.4 — priorites =====================
F=m1-priorites.txt; : > "$CAP/$F"
titre "1.4 — Priorites CPU et E/S d'un processus en cours"
nice -n 19 sha256sum /dev/zero & NPID=$!
sleep 1
marque $F "Lancement avec nice -n 19"
run $F "ps -o pid,ni,pri,cls,rtprio,comm -p $NPID"
marque $F "Modification a chaud"
run $F "renice -n 5 -p $NPID"
run $F "ionice -c 2 -n 7 -p $NPID ; ionice -p $NPID"
run $F "chrt -p $NPID"
run $F "ps -o pid,ni,pri,cls,rtprio,comm -p $NPID"
kill "$NPID"; wait "$NPID" 2>/dev/null

# ===================== bilan =====================
titre "Bilan mission 1"
[[ $(systemctl is-enabled $SVC) == enabled ]] && ok "is-enabled $SVC -> enabled" || ko "$SVC pas enabled"
[[ $MM == 100663296 ]] && ok "MemoryMax -> 100663296" || ko "MemoryMax -> $MM"
systemctl list-dependencies helios.target --no-pager | grep -q "$SVC" && ok "list-dependencies helios.target -> $SVC" || ko "target"
info "Captures dans $CAP — suite : mission 2 (m2-edge.sh sur srv-edge, puis m2-core.sh ici)"
