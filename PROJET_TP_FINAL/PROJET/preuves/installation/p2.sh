#!/usr/bin/bash
# p2.sh — PROJET, apres le redemarrage : tout doit etre persistant, l'audit doit rester 9/9.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root
SB=/usr/local/sbin
PRINTK=$(awk '{print $1}' /proc/sys/kernel/printk); dmesg -n 1
trap 'dmesg -n "$PRINTK"' EXIT
sleep 20      # laisse le temps au timer de publier etat.json apres le demarrage

ecran 15-apres-reboot.txt "Apres redemarrage : persistance et audit"
run "uptime -s ; journalctl --list-boots --no-pager | tail -2"
run "systemctl is-active helios-suivi.service helios-suivi-publish.timer helios-suivi-backup.timer zabbix-agent2 sysstat-collect.timer helios-collect.service helios-watch-auth.timer firewalld | paste -sd' '"
printf '$ %s\n' "$SB/helios-suivi-audit.sh ; echo rc=\$?" | tee -a "$PRV/$F"
$SB/helios-suivi-audit.sh | tee "$PRV/audit-apres-redemarrage.txt" | tee -a "$PRV/$F" ; echo "rc=${PIPESTATUS[0]}" | tee -a "$PRV/audit-apres-redemarrage.txt" "$PRV/$F"
pause

ecran 16-E10-detection.txt "E10 — L'audit detecte les pannes (puis on repare)"
run "firewall-cmd -q --zone=internal --remove-port=8080/tcp ; echo '8080 retire du pare-feu (runtime)' ; $SB/helios-suivi-audit.sh | grep -E '^\[KO\]|^Bilan' | cut -c1-124 ; echo \"rc=\${PIPESTATUS[0]}\" ; firewall-cmd -q --zone=internal --add-port=8080/tcp ; echo '8080 remis'"
run "L=\$(ls -1 /srv/helios/archives/suivi/suivi-*.tar.gz | sort | tail -1) ; cp -p \$L.sha256 /root/sha.bak ; echo '0000  '\$(basename \$L) > \$L.sha256 ; echo 'empreinte de la derniere sauvegarde faussee' ; $SB/helios-suivi-audit.sh | grep -E '^\[KO\]|^Bilan' | cut -c1-124 ; cp -p /root/sha.bak \$L.sha256 ; echo 'empreinte remise'"
run "$SB/helios-suivi-audit.sh | tail -1 ; echo \"rc=\${PIPESTATUS[0]}\""
pause

# Recuperation du rendu depuis le PC : scp -P 2242 -r david@192.168.56.10:/tmp/res PROJET-res
journalctl -u helios-suivi-publish.service -n 20 --no-pager > "$PRV/16-journal-publication.txt" 2>&1
rm -rf /tmp/res ; cp -r "$OUT" /tmp/res ; chown -R david:david /tmp/res
ecran 17-fin.txt "Fin : resultats copies dans /tmp/res"
info "Sur le PC : scp -P 2242 -r david@192.168.56.10:/tmp/res PROJET-res"
