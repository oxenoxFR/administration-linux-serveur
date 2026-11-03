#!/usr/bin/bash
# Mission 3 + bonus — script d'archivage robuste, codes retour, timer systemd,
# comparaison avec cron (observations reelles), path unit.
# A lancer sur srv-core, en root, apres la mission 1 (le collecteur doit tourner). Relancable.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core

ARCH=/usr/local/sbin/helios-archive.sh
CSV=/var/lib/helios/telemetry.csv
STAMP=/var/lib/systemd/timers/stamp-helios-archive.timer

systemctl is-active -q helios-collect.service || { ko "helios-collect.service ne tourne pas : fais d'abord la mission 1"; exit 1; }

# ===================== 3.1 — script + codes retour =====================
F=m3-codes-retour.txt; : > "$CAP/$F"
titre "3.1 — Installation de helios-archive.sh"
install -m 0750 "$CFG/helios-archive.sh" "$ARCH"
bash -n "$ARCH" && ok "Syntaxe OK (bash -n)"
run $F "ls -l $ARCH"
sleep 6   # laisse le collecteur ecrire au moins une ligne

marque $F "Cas nominal (attendu 0)"
run $F "$ARCH"; RC0=$?
run $F "journalctl -t helios-archive -n 10 --no-pager"
run $F "ls -l /var/lib/helios/archives/"

marque $F "Verrou deja pris (attendu 2)"
( exec 9>/run/lock/helios-archive.lock ; flock 9 ; sleep 20 ) &
LPID=$!
sleep 1
run $F "$ARCH"; RC2=$?
wait "$LPID"

marque $F "Source absente (attendu 3)"
info "On arrete le collecteur le temps du test, sinon il recree telemetry.csv sous 5 s."
systemctl stop helios-collect.service
mv "$CSV" /tmp/t.csv
run $F "$ARCH"; RC3=$?
mv /tmp/t.csv "$CSV"
systemctl start helios-collect.service
run $F "journalctl -t helios-archive -n 8 --no-pager"

{ echo; echo "### Codes retour observes : nominal=$RC0  verrou=$RC2  source_absente=$RC3"; } | tee -a "$CAP/$F"
valeur RC0 "$RC0"; valeur RC2 "$RC2"; valeur RC3 "$RC3"
[[ $RC0 == 0 ]] && ok "rc nominal = 0" || ko "rc nominal = $RC0 (attendu 0)"
[[ $RC2 == 2 ]] && ok "rc verrou = 2"  || ko "rc verrou = $RC2 (attendu 2)"
[[ $RC3 == 3 ]] && ok "rc source absente = 3" || ko "rc source absente = $RC3 (attendu 3)"

# ===================== 3.2 — timer =====================
F=m3-timer.txt; : > "$CAP/$F"
titre "3.2 — Service oneshot + timer"
install -m 0644 "$CFG/helios-archive.service" /etc/systemd/system/helios-archive.service
install -m 0644 "$CFG/helios-archive.timer"   /etc/systemd/system/helios-archive.timer
run $F "systemd-analyze verify /etc/systemd/system/helios-archive.service /etc/systemd/system/helios-archive.timer"
systemctl daemon-reload
run $F "systemctl enable --now helios-archive.timer"
run $F "systemd-analyze calendar '*-*-* 02:30:00' --iterations=3"
run $F "systemctl list-timers helios-archive.timer --all --no-pager"
marque $F "Declenchement manuel du service"
run $F "systemctl start helios-archive.service && systemctl status helios-archive.service --no-pager"
run $F "journalctl -u helios-archive.service -n 10 --no-pager"

# --- observation : rattrapage (Persistent=yes) ---
marque $F "Observation Persistent=yes : on simule 2 jours de VM eteinte"
info "On antidate la derniere execution memorisee du timer, puis on le redemarre."
T0=$(date +%s)
run $F "touch -d '2 days ago' $STAMP && ls -l --time-style=long-iso $STAMP"
run $F "systemctl restart helios-archive.timer"
DECL=""
for _ in $(seq 1 30); do
    if journalctl -t helios-archive --since "@$T0" --no-pager -q | grep -q demarrage; then
        DECL="$(( $(date +%s) - T0 ))"; break
    fi
    sleep 2
done
run $F "journalctl -u helios-archive.service --since '@$T0' --no-pager"
run $F "systemctl list-timers helios-archive.timer --all --no-pager"
if [[ -n $DECL ]]; then
    ok "Rattrapage : execution manquee relancee ~${DECL} s apres le redemarrage du timer"
    valeur PERSISTENT "execution manquee rattrapee automatiquement ~${DECL} s apres le redemarrage du timer"
else
    ko "Pas de rattrapage observe en 60 s"
    valeur PERSISTENT "pas de rattrapage observe (a verifier dans captures/m3-timer.txt)"
fi
valeur TIMER_NEXT "$(systemctl show -p NextElapseUSecRealtime --value helios-archive.timer)"

# ===================== 3.2 — equivalent cron =====================
F=m3-cron.txt; : > "$CAP/$F"
titre "3.2 — Equivalent cron (version de l'enonce), puis retrait"
rpm -q cronie &>/dev/null || run $F "dnf -y install cronie"
run $F "systemctl enable --now crond"
printf 'MAILTO=""\n30 2 * * * root /usr/local/sbin/helios-archive.sh\n' > /etc/cron.d/helios-legacy
run $F "cat /etc/cron.d/helios-legacy"
run $F "systemctl restart crond ; journalctl -u crond -n 10 --no-pager"

marque $F "Observation : meme script lance par cron chaque minute pour voir ce que cron journalise"
printf 'MAILTO=""\n* * * * * root /usr/local/sbin/helios-archive.sh\n' > /etc/cron.d/helios-legacy
systemctl restart crond
T1=$(date +%s)
ATTENTE=$(( 70 - 10#$(date +%S) ))
info "Attente de la prochaine minute pleine (~${ATTENTE} s)..."
sleep "$ATTENTE"
run $F "journalctl -u crond --since '@$T1' --no-pager"
run $F "journalctl -t helios-archive --since '@$T1' --no-pager"
valeur CRON_JOURNAL "$(journalctl -u crond --since "@$T1" --no-pager -q | grep -m1 CMD | sed 's/^.*CROND/CROND/')"
marque $F "Retrait"
run $F "rm -f /etc/cron.d/helios-legacy && systemctl restart crond"
run $F "ls /etc/cron.d/"

# ===================== bonus — path unit =====================
F=m3-bonus-path.txt; : > "$CAP/$F"
titre "Bonus — declenchement sur depot de fichier (path unit)"
install -d -m 0775 -o helios -g helios /srv/helios/inbox
install -m 0644 "$CFG/helios-inbox.path" /etc/systemd/system/helios-inbox.path
run $F "systemd-analyze verify /etc/systemd/system/helios-inbox.path"
systemctl daemon-reload
run $F "systemctl enable --now helios-inbox.path"
T2=$(date +%s)
run $F "touch /srv/helios/inbox/test.csv ; sleep 3 ; journalctl -t helios-archive -n 5 --no-pager"
if journalctl -t helios-archive --since "@$T2" --no-pager -q | grep -q demarrage; then
    ok "Le depot d'un fichier dans l'inbox a declenche l'archivage"
    valeur BONUS "le depot de test.csv a declenche helios-archive.service en moins de 3 s"
else
    ko "Pas de declenchement observe"
    valeur BONUS "pas de declenchement observe"
fi

# ===================== bilan =====================
titre "Bilan mission 3"
run m3-timer.txt "systemctl list-timers helios-archive.timer --all --no-pager"
info "NEXT doit etre vers 02:30 (+ jusqu'a 2 min de RandomizedDelaySec)."
info "Il ne reste plus qu'a lancer ./remplir-rapport.sh puis rapatrier le dossier TP1."
