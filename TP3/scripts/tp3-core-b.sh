#!/usr/bin/bash
# TP3 — partie B sur srv-core (root), APRES le redemarrage de la partie A :
# investigation des journaux, detection automatique + blocage, bonus, rassemblement des livrables.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core

########################################################################
titre "MISSION 3.1 — Persistance prouvee par plusieurs demarrages"
########################################################################
F=m3-boots.txt; : > "$CAP/$F"
run $F "journalctl --list-boots"
NB=$(journalctl --list-boots --no-pager 2>/dev/null | tail -n +2 | grep -c .); valeur BOOTS "$NB"
(( NB >= 2 )) && ok "$NB demarrages conserves" || ko "Un seul demarrage visible"
run $F "auditctl -s | grep enabled"

########################################################################
titre "MISSION 3.2 — Requetes d'investigation"
########################################################################
F=m3-investigation.txt; : > "$CAP/$F"
marque $F "1. Avertissements de sshd sur 2 h"
run $F "journalctl -u sshd.service --since '-2h' -p warning -o short-iso --no-pager | tail -20"
marque $F "2. Utilisateurs inconnus, echecs et connexions acceptees"
run $F "journalctl _SYSTEMD_UNIT=sshd.service -g 'Invalid user|Failed|Accepted' --no-pager | tail -20"
marque $F "3. Toute l'activite d'authentification du jour (facility authpriv)"
run $F "journalctl --facility=authpriv --since today --no-pager | tail -20"
marque $F "4. Ce qu'a fait nadia (UID 5101) aujourd'hui"
run $F "journalctl _UID=5101 --since today --no-pager | tail"
marque $F "5. Utilisation de sudo au format JSON"
run $F "journalctl -t sudo --since today -o json-pretty | head -40"
marque $F "6. Erreurs du demarrage precedent"
run $F "journalctl -b -1 -p err --no-pager | tail -20"
marque $F "7. Echecs et sessions de connexion"
run $F "lastb -n 15 ; last -F -n 10"
run $F "lslogins -u --output=USER,PWD-CHANGE,PWD-EXPIR,LAST-LOGIN,FAILED-LOGIN"

########################################################################
titre "MISSION 3.4 — Detection automatique et blocage"
########################################################################
F=m3-watchauth.txt; : > "$CAP/$F"
bash -n "$CFG/helios-watchauth.sh" || { ko "helios-watchauth.sh invalide"; exit 1; }
install -m 0750 "$CFG/helios-watchauth.sh" /usr/local/sbin/helios-watchauth.sh
install -m 0644 "$CFG/helios-watch-auth.service" /etc/systemd/system/helios-watch-auth.service
install -m 0644 "$CFG/helios-watch-auth.timer"   /etc/systemd/system/helios-watch-auth.timer
run $F "systemd-analyze verify /etc/systemd/system/helios-watch-auth.service /etc/systemd/system/helios-watch-auth.timer"
systemctl daemon-reload
run $F "systemctl enable --now helios-watch-auth.timer ; systemctl list-timers helios-watch-auth.timer --no-pager"
marque $F "Code retour 2 si une instance tourne deja"
( exec 9>/run/lock/helios-watchauth.lock ; flock 9 ; sleep 5 ) & sleep 1
/usr/local/sbin/helios-watchauth.sh; RC2=$?; wait
echo "rc avec verrou pris : $RC2" | tee -a "$CAP/$F"; valeur RC_VERROU "$RC2"

pause "Sur srv-edge lance :  bash ~/TP3/scripts/tp3-edge.sh attaque   puis reviens ici"
F=m3-blocage.txt; : > "$CAP/$F"
run $F "journalctl -u sshd --since '-5min' -g 'Invalid user' --no-pager | tail"
run $F "systemctl start helios-watch-auth.service"
run $F "journalctl -t helios-watch-auth -n 10 --no-pager"
run $F "firewall-cmd --ipset=helios-blacklist --get-entries"
run $F "nft list set inet firewalld helios-blacklist"
marque $F "Idempotence : un 2e passage ne realerte pas"
run $F "systemctl start helios-watch-auth.service ; journalctl -t helios-watch-auth -n 3 --no-pager"
if firewall-cmd -q --ipset=helios-blacklist --query-entry=192.168.56.11; then
    ok "192.168.56.11 (srv-edge) est bloquee"; valeur BLOQUE "192.168.56.11 ajoutee a helios-blacklist"
else
    ko "192.168.56.11 n'est pas dans helios-blacklist"
fi

pause "Sur srv-edge lance :  bash ~/TP3/scripts/tp3-edge.sh bloque   (pour constater le blocage) puis reviens ici"
marque $F "Deblocage de srv-edge"
run $F "systemctl stop helios-watch-auth.timer"
run $F "firewall-cmd --ipset=helios-blacklist --remove-entry=192.168.56.11 ; firewall-cmd --permanent --ipset=helios-blacklist --remove-entry=192.168.56.11"
sed -i '/192.168.56.11/d' /var/lib/helios/blocked.txt
run $F "systemd-run --on-active=11min --timer-property=RemainAfterElapse=no systemctl start helios-watch-auth.timer"
run $F "firewall-cmd --ipset=helios-blacklist --get-entries ; echo '(vide = debloque)'"

########################################################################
titre "BONUS 2 et 3 — Rapports auditd et revue cryptographique"
########################################################################
F=bonus-aureport.txt; : > "$CAP/$F"
run $F "auditctl -s | grep enabled"
run $F "aureport --start this-week --summary -i"
run $F "aureport --executable --summary -i | head -25"
F=bonus-crypto.txt; : > "$CAP/$F"
run $F "ssh -Q cipher ; echo ; ssh -Q kex"
run $F "sshd -T | grep -iE '^(ciphers|kexalgorithms|macs|hostkeyalgorithms|authenticationmethods|passwordauthentication)'"

########################################################################
titre "Livrables"
########################################################################
firewall-cmd --list-all-zones > "$CFG/zones.txt"
cp /etc/ssh/sshd_config.d/10-helios-hardening.conf /etc/ssh/sshd_config.d/05-helios-crypto.conf /etc/issue.net \
   /etc/systemd/journald.conf.d/50-helios.conf /etc/audit/rules.d/90-helios.rules "$CFG/" 2>/dev/null
cp /etc/sysctl.d/90-helios-sshd.conf "$CFG/" 2>/dev/null
ok "configs/ mis a jour"
titre "Bilan TP3"
cat "$VALEURS"
info "Captures dans $CAP."
