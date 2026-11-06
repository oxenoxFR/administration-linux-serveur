#!/usr/bin/bash
# p3.sh — PROJET, reprise de E9 : « tar » n'etait pas installe sur le socle minimal (la sauvegarde
# a donc renvoye 3 = prerequis manquant, et le test de restauration n'a pas pu se faire).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root
export WWW=/srv/helios/suivi/www ARCH=/srv/helios/archives/suivi
SB=/usr/local/sbin ; SD=/etc/systemd/system
PRINTK=$(awk '{print $1}' /proc/sys/kernel/printk); dmesg -n 1
trap 'dmesg -n "$PRINTK"' EXIT

ecran 10-E9-sauvegarde.txt "E9 (reprise) — tar installe, puis sauvegarde"
run "rpm -q tar || dnf -y -q install tar ; rpm -q tar"
if [[ ! -f $WWW/index.html ]]; then      # supprime par le test de restauration rate : lea le redepose
    su - lea -c "cat > $WWW/index.html" < "$SRC_CFG/index.html"
    run "echo 'index.html redepose par lea (le 1er test de restauration avait echoue faute de tar)' ; ls -l $WWW/index.html"
fi
run "systemctl start helios-suivi-backup.service ; systemctl show -p Result -p ExecMainStatus helios-suivi-backup.service ; journalctl -t helios-suivi-backup -n 3 --no-pager -o cat"
run "for i in 1 2 3 4 5 6 7 8 ; do sleep 1 ; $SB/helios-suivi-backup.sh || echo rc=\$? ; done ; echo \"archives conservees : \$(ls $ARCH/suivi-*.tar.gz | wc -l) (9 sauvegardes lancees)\""
L=$(ls -1 "$ARCH"/suivi-*.tar.gz | sort | tail -1) ; export L
run "cd $ARCH && ls -1 | tail -4 && sha256sum -c \$(basename $L).sha256"
run "tar -tzf $L | grep -v '/\$' | grep -v etat.json"
run "systemctl list-timers helios-suivi-backup.timer --no-pager | head -2 ; systemctl show -p Persistent helios-suivi-backup.timer"
pause

ecran 11-E9-restauration.txt "E9.5 — Restauration prouvee"
T=/root/restauration-test ; rm -rf "$T" ; mkdir -p "$T"
run "t0=\$(date +%s.%N) ; tar --acls --xattrs --selinux -xzpf $L -C $T && echo \"(a) archive extraite dans $T en \$(depuis \$t0) s\""
run "diff <(cd / && getfacl -R -p srv/helios/suivi/www 2>/dev/null | grep -v 'file: .*etat') <(cd $T && getfacl -R -p srv/helios/suivi/www 2>/dev/null | grep -v 'file: .*etat') && echo '(a) ACL de www : identiques entre la production et l archive'"
run "getfacl -p $WWW/index.html > /root/acl-index-avant.txt ; sha256sum $WWW/index.html > /root/sha-index-avant.txt ; rm -f $WWW/index.html ; echo '(b) incident : index.html supprime' ; curl -s http://127.0.0.1:8080/ | grep -o '<title>.*</title>'"
run "t0=\$(date +%s.%N) ; tar --acls --xattrs --selinux -xzpf $L -C / srv/helios/suivi/www/index.html ; echo \"(b) index.html restaure seul en \$(depuis \$t0) s\""
run "ls -l $WWW/index.html ; diff <(getfacl -p $WWW/index.html) /root/acl-index-avant.txt && echo 'ACL identiques a avant l incident' ; sha256sum -c /root/sha-index-avant.txt ; curl -s http://127.0.0.1:8080/ | grep -o '<title>.*</title>'"
pause

ecran 13-E10-audit.txt "E10 (bonus) — Audit de conformite"
$SB/helios-suivi-backup.sh
printf '$ %s\n' "$SB/helios-suivi-audit.sh ; echo rc=\$?" | tee -a "$PRV/$F"
$SB/helios-suivi-audit.sh | tee "$PRV/audit.txt" | tee -a "$PRV/$F" ; echo "rc=${PIPESTATUS[0]}" | tee -a "$PRV/audit.txt" "$PRV/$F"
run "systemctl stop helios-suivi.service ; $SB/helios-suivi-audit.sh | grep -E 'KO|Bilan' | cut -c1-124 ; echo \"rc=\${PIPESTATUS[0]}   (portail arrete)\" ; systemctl start helios-suivi.service"
pause

ecran 05-E4-units.txt "E4 — Etat du portail et rattachement a helios.target"
run "systemctl status helios-suivi.service --no-pager -n 0 | head -12"
run "systemctl show -p Wants helios.target ; ls -l $SD/helios.target.wants/"
run "systemctl list-timers --no-pager | grep -E 'helios-suivi|NEXT'"
pause

for f in helios-suivi.service helios-suivi-publish.service helios-suivi-publish.timer helios-suivi-backup.service helios-suivi-backup.timer; do cp "$SD/$f" "$CFG/"; done
cp $SB/helios-suivi-publish.sh $SB/helios-suivi-backup.sh $SB/helios-suivi-audit.sh /etc/sudoers.d/92-helios-suivi \
   /etc/zabbix/zabbix_agent2.d/helios-suivi.conf "$CFG/"
getfacl -R -p "$WWW" > "$CFG/getfacl-www.txt" 2>/dev/null
firewall-cmd --zone=internal --list-all > "$CFG/firewall-internal.txt"
cp -f "$P_DIR"/*.sh "$OUT/" 2>/dev/null
ecran 14-fin.txt "Fin de la reprise"
info "Il reste a redemarrer pour verifier que tout est persistant, puis : bash /tmp/p/p2.sh"
read -rp "Redemarrer srv-core maintenant ? [o/N] " r </dev/tty
[[ $r == [oO]* ]] && systemctl reboot
