#!/usr/bin/bash
# p1.sh — PROJET « portail de suivi des tournees » : installation + preuves, sur srv-core en root.
# Chaque ecran se termine par une pause : capture d'ecran de la console, puis Entree.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root
[[ $(hostname -s) == srv-core ]] || { echo "A lancer sur srv-core"; exit 1; }

export LEA_MDP='Helios-Suivi-2026'          # mot de passe de lab impose par la fiche (§2)
export WWW=/srv/helios/suivi/www ARCH=/srv/helios/archives/suivi
SB=/usr/local/sbin ; SD=/etc/systemd/system
UNITS_TP=(helios-collect.service helios.target helios-archive.service helios-archive.timer
          helios-watch-auth.service helios-watch-auth.timer helios-collect.service.d/override.conf)
# Pas de messages du noyau (journalisation du pare-feu) par-dessus les captures de la console
PRINTK=$(awk '{print $1}' /proc/sys/kernel/printk); dmesg -n 1
trap 'dmesg -n "$PRINTK"' EXIT

######################################################################## 0
ecran 00-prerequis.txt "Prerequis (etat de fin du TP3)"
( cd "$SD" && sha256sum "${UNITS_TP[@]}" 2>/dev/null ) > "$PRV/00-units-tp-avant.sha256"
run "systemctl is-active helios-collect.service ; wc -l < /var/lib/helios/telemetry.csv ; sleep 6 ; wc -l < /var/lib/helios/telemetry.csv"
run "systemctl cat helios.target | head -6"
run "firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"
run "sshd -T | grep -E '^(port|allowgroups|passwordauthentication) '"
run "systemctl is-active helios-watch-auth.timer ; getenforce"
pause

######################################################################## E8.1
ecran 01-E8-installation-zabbix.txt "E8.1 — Agent Zabbix installe EN PREMIER"
if [[ -f /etc/yum.repos.d/epel.repo ]] && ! grep -q '^excludepkgs=zabbix\*' /etc/yum.repos.d/epel.repo; then
    sed -i '/^\[epel\]$/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
fi
run "grep -H '^excludepkgs' /etc/yum.repos.d/epel.repo 2>/dev/null || echo 'EPEL non installe : rien a exclure'"
if ! rpm -q zabbix-release &>/dev/null; then
    run "rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rocky/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm" \
 || run "rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rhel/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm"
    dnf clean all &>/dev/null
fi
run "dnf -y -q install zabbix-agent2 zabbix-get sysstat && echo 'installation terminee'"
run "rpm -q zabbix-release zabbix-agent2 zabbix-get sysstat"
run "systemctl enable --now zabbix-agent2 sysstat sysstat-collect.timer sysstat-summary.timer 2>&1 | grep -v '^Created symlink' ; systemctl is-active zabbix-agent2 sysstat-collect.timer ; systemctl is-enabled zabbix-agent2 sysstat-collect.timer"
run "grep -E '^(Server|ServerActive|Hostname|Include)=' /etc/zabbix/zabbix_agent2.conf ; getent passwd zabbix"
getent passwd zabbix >/dev/null || { ko "compte zabbix absent : E2 impossible, arret"; pause "Entree pour quitter"; exit 1; }
pause

######################################################################## E1
ecran 02-E1-comptes.txt "E1 — Comptes et groupe"
getent group suivi >/dev/null || groupadd -g 5003 suivi
if ! getent passwd lea >/dev/null; then
    useradd -u 5104 -g suivi -c 'Lea Fabre - responsable suivi des tournees' -m -s /bin/bash lea
    usermod -p "$(openssl passwd -6 "$LEA_MDP")" lea
fi
chage -m 1 -M 90 -W 14 -I 7 lea
for g in wheel ssh-admins; do id -nG lea | tr ' ' '\n' | grep -qx "$g" && gpasswd -d lea "$g" >/dev/null; done
getent passwd helios-suivi >/dev/null || \
    useradd -r -M -d /srv/helios/suivi -s /sbin/nologin -c 'Portail de suivi des tournees' helios-suivi
run "getent group suivi ; id lea ; getent passwd lea helios-suivi"
run "chage -l lea"
run "id -nG lea | tr ' ' '\n' | grep -xE 'wheel|ssh-admins' || echo 'lea : ni wheel ni ssh-admins'"
run "id helios-suivi ; ls -d /home/helios-suivi ; ls /home"
pause

######################################################################## E2
ecran 03-E2-droits.txt "E2 — Repertoire publie : setgid et ACL (1/2)"
install -d -m 0750 -o root -g suivi /srv/helios/suivi
setfacl -m u:helios-suivi:r-x,u:zabbix:--x /srv/helios/suivi
install -d -o root -g suivi "$WWW" ; chown root:suivi "$WWW" ; chmod 2770 "$WWW"
setfacl -m u:helios-suivi:rwx,u:zabbix:--x,g::rwx,o::--- "$WWW"
setfacl -d -m u::rwX,g::rwX,u:helios-suivi:rX,o::--- "$WWW"
for u in helios-suivi zabbix lea; do            # /srv/helios doit etre traversable (x) par ces comptes
    runuser -u "$u" -- test -x /srv/helios || setfacl -m "u:$u:--x" /srv/helios
done
if ! runuser -u helios-suivi -- test -r /var/lib/helios/telemetry.csv; then   # ajout, pas de modification du TP1
    setfacl -m u:helios-suivi:--x /var/lib/helios ; setfacl -m u:helios-suivi:r-- /var/lib/helios/telemetry.csv
fi
run "ls -ld /srv/helios /srv/helios/suivi $WWW"
run "getfacl -p $WWW"
pause

ecran 03-E2-droits.txt "E2 — Fichiers crees par lea, et qui peut quoi (2/2)"
su - lea -c "cat > $WWW/index.html" < "$SRC_CFG/index.html"
run "su - lea -c umask ; ls -l $WWW/index.html ; getfacl -p --omit-header $WWW/index.html"
run "su - lea -c 'umask 077 ; touch $WWW/essai-umask077' ; ls -l $WWW/essai-umask077 ; rm -f $WWW/essai-umask077"
run "runuser -u helios-suivi -- cat $WWW/index.html > /dev/null && echo 'helios-suivi lit index.html : OK'"
run "runuser -u nadia -- cat $WWW/index.html"
run "runuser -u zabbix -- ls $WWW"
run "runuser -u zabbix -- stat -c '%n : %U:%G %A' $WWW/index.html"
pause

######################################################################## E3
ecran 04-E3-publication.txt "E3 — Script de publication : codes retour"
install -m 0755 -o root -g root "$SRC_CFG/helios-suivi-publish.sh" $SB/helios-suivi-publish.sh
run "runuser -u helios-suivi -- $SB/helios-suivi-publish.sh ; echo \"rc=\$?   (attendu 0)\""
run "flock $SB/helios-suivi-publish.sh sleep 4 & sleep 1 ; runuser -u helios-suivi -- $SB/helios-suivi-publish.sh ; echo \"rc=\$?   (attendu 2 : verrou deja pris)\" ; wait"
run "runuser -u nadia -- $SB/helios-suivi-publish.sh ; echo \"rc=\$?   (attendu 3 : www non inscriptible pour nadia)\""
run "printf 'pas,une,mesure\n' > /tmp/tele-invalide.csv ; chmod 644 /tmp/tele-invalide.csv ; runuser -u helios-suivi -- env HELIOS_TELEMETRY=/tmp/tele-invalide.csv $SB/helios-suivi-publish.sh ; echo \"rc=\$?   (attendu 1 : ligne invalide)\" ; rm -f /tmp/tele-invalide.csv"
run "python3 -m json.tool $WWW/etat.json ; ls -l $WWW/etat.json"
run "journalctl -t helios-suivi-publish -n 6 --no-pager -o short-iso | cut -c1-118"
pause

######################################################################## E4
ecran 05-E4-units.txt "E4 — Units : portail et publication (1/2)"
for u in helios-suivi.service helios-suivi-publish.service helios-suivi-publish.timer; do
    install -m 0644 -o root -g root "$SRC_CFG/$u" "$SD/$u"
done
systemctl daemon-reload
run "systemd-analyze verify $SD/helios-suivi.service $SD/helios-suivi-publish.service $SD/helios-suivi-publish.timer && echo 'verify : OK'"
systemctl enable --now helios-suivi.service helios-suivi-publish.timer &>/dev/null
systemctl start helios-suivi-publish.service ; sleep 2
if [[ $(systemctl show -p Result --value helios-suivi-publish.service) != success ]]; then
    journalctl -u helios-suivi-publish.service -n 8 --no-pager > "$PRV/04-E3-echec-unit.txt" 2>&1
    for d in PrivateNetwork PrivateDevices MemoryDenyWriteExecute SystemCallFilter RestrictAddressFamilies; do
        sed -i "/^$d=/d" "$SD/helios-suivi-publish.service"
        systemctl daemon-reload ; systemctl reset-failed helios-suivi-publish.service
        systemctl start helios-suivi-publish.service
        echo "publication : directive retiree : $d" | tee -a "$PRV/05-E4-directives-retirees.txt"
        [[ $(systemctl show -p Result --value helios-suivi-publish.service) == success ]] && break
    done
fi
code200() { [[ $(curl -s -o /dev/null -m 3 -w '%{http_code}' http://127.0.0.1:8080/etat.json) == 200 ]]; }
if ! code200; then
    # Le durcissement casse le portail : on retire les directives les plus risquees une par une, et on le note
    journalctl -u helios-suivi.service -n 5 --no-pager > "$PRV/05-E4-echec-demarrage.txt" 2>&1
    for d in ReadOnlyPaths MemoryDenyWriteExecute ProcSubset ProtectProc SystemCallFilter; do
        sed -i "/^$d=/d" "$SD/helios-suivi.service"
        systemctl daemon-reload ; systemctl reset-failed helios-suivi.service ; systemctl restart helios-suivi.service ; sleep 3
        echo "directive retiree : $d" | tee -a "$PRV/05-E4-directives-retirees.txt"
        code200 && break
    done
fi
run "systemctl status helios-suivi.service --no-pager -n 0 | head -11"
run "systemctl list-dependencies helios.target --plain --no-pager"
run "systemctl show -p User -p Restart -p MemoryMax -p CPUQuotaPerSecUSec helios-suivi.service"
run "systemctl show -p User -p Result -p ExecMainStatus helios-suivi-publish.service ; systemctl list-timers helios-suivi-publish.timer --no-pager | head -2"
run "curl -s -o /dev/null -w 'GET /          -> %{http_code}\n' http://127.0.0.1:8080/ ; curl -s -o /dev/null -w 'GET /etat.json -> %{http_code}\n' http://127.0.0.1:8080/etat.json"
pause

ecran 05-E4-units.txt "E4 — Durcissement, crash et non-modification des units du TP (2/2)"
systemd-analyze security --no-pager helios-suivi.service > "$PRV/05-E4-security-complet.txt" 2>&1
run "systemd-analyze security --no-pager helios-suivi.service | tail -1"
MP=$(systemctl show -p MainPID --value helios-suivi.service)
run "echo 'Le portail (espace de noms du service, en helios-suivi) essaie d ecrire :' ; for p in $WWW/essai /tmp/essai /var/tmp/essai /dev/shm/essai /var/lib/helios/essai ; do if nsenter -t $MP -m -S \$(id -u helios-suivi) -G \$(id -g helios-suivi) -- touch \$p 2>/tmp/err ; then echo \"  ECRITURE POSSIBLE : \$p\" ; else sed 's/^/  refuse -> /' /tmp/err ; fi ; done ; rm -f $WWW/essai /tmp/err"
run "P1=\$(systemctl show -p MainPID --value helios-suivi.service) ; t0=\$(date +%s.%N) ; kill -9 \$P1 ; sleep 0.5 ; for i in \$(seq 100) ; do [ \"\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/etat.json)\" = 200 ] && break ; sleep 0.2 ; done ; echo \"kill -9 sur PID \$P1 -> nouveau PID \$(systemctl show -p MainPID --value helios-suivi.service), de nouveau 200 apres \$(depuis \$t0) s\" ; systemctl show -p NRestarts helios-suivi.service"
run "cd $SD && sha256sum --quiet -c $PRV/00-units-tp-avant.sha256 && echo 'units des TP1 a TP3 : identiques avant/apres le projet'"
run "find $SD -newer $PRV/00-units-tp-avant.sha256 \\( -type f -o -type l \\) | sort"
pause

######################################################################## E5
ecran 06-E5-sudo.txt "E5 — Delegation sudo pour le groupe suivi"
run "visudo -c -f $SRC_CFG/92-helios-suivi && install -m 0440 -o root -g root $SRC_CFG/92-helios-suivi /etc/sudoers.d/92-helios-suivi && ls -l /etc/sudoers.d/92-helios-suivi && visudo -c | tail -1"
run "sudo -l -U lea | sed -n '/may run the following/,\$p'"
run "sudo -l -U lea /usr/bin/systemctl restart sshd ; echo \"rc=\$?  (rien de liste = refuse)\""
run "sudo -l -U lea /usr/bin/journalctl --vacuum-time=1s ; echo \"rc=\$?  (refuse : aucune option ajoutee possible)\""
run "printf '%s\n' \"\$LEA_MDP\" | su - lea -c 'sudo -S -p \"\" /usr/bin/systemctl restart helios-suivi.service' 2>&1 | tail -2 ; echo \"essai reel en lea : restart helios-suivi rc=\${PIPESTATUS[1]}\""
run "printf '%s\n' \"\$LEA_MDP\" | su - lea -c 'sudo -S -p \"\" /usr/bin/systemctl restart sshd' 2>&1 | tail -1"
run "printf '%s\n' \"\$LEA_MDP\" | su - lea -c 'sudo -S -p \"\" /usr/bin/journalctl -u helios-suivi.service -n 100 --no-pager' 2>&1 | tail -2 | cut -c1-118"
pause

######################################################################## E6
ecran 07-E6-parefeu.txt "E6 — Pare-feu : 8080 seulement dans internal"
firewall-cmd -q --zone=internal --query-port=8080/tcp || firewall-cmd -q --zone=internal --add-port=8080/tcp
firewall-cmd -q --permanent --zone=internal --query-port=8080/tcp || firewall-cmd -q --permanent --zone=internal --add-port=8080/tcp
run "firewall-cmd --zone=internal --query-port=8080/tcp ; firewall-cmd --permanent --zone=internal --query-port=8080/tcp"
run "firewall-cmd --zone=internal --list-all | grep -vE '^  (icmp-block-inversion|forward-ports|source-ports|icmp-blocks|protocols|masquerade):'"
run "n=0 ; for z in \$(firewall-cmd --get-zones) ; do [ \$z = internal ] && continue ; for m in '' --permanent ; do firewall-cmd \$m --zone=\$z --list-all | grep -q 8080 && { echo \"8080 dans \$z \$m\" ; n=1 ; } ; done ; done ; [ \$n = 0 ] && echo 'aucune autre zone (runtime et permanent) ne contient 8080'"
run "firewall-cmd --get-default-zone ; nft list ruleset | grep -n 8080"
pause "Sur srv-edge : bash /tmp/e.sh   (puis reviens ici et appuie sur Entree)"

######################################################################## E7
ecran 08-E7-non-regression.txt "E7 — Non-regression de la securite"
run "sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|allowgroups) '"
run "ssh -p 2242 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 lea@10.42.0.10 true ; echo \"rc=\$?  (attendu 255 : lea refusee)\""
sleep 1
run "journalctl -u sshd --since today --no-pager -o short-iso | grep -E 'User lea from' | tail -3 | cut -c1-124"
run "systemctl is-active helios-watch-auth.timer firewalld ; getenforce ; ls -d /var/log/journal/\$(cat /etc/machine-id) ; journalctl --list-boots --no-pager | tail -2"
pause

######################################################################## E8
ecran 09-E8-supervision.txt "E8 — Supervision : sondes Zabbix et sar"
install -m 0644 -o root -g root "$SRC_CFG/helios-suivi.conf" /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
systemctl restart zabbix-agent2 ; sleep 3
run "grep '^UserParameter' /etc/zabbix/zabbix_agent2.d/helios-suivi.conf | cut -c1-124"
run "ps -eo user,label,cmd | grep '[z]abbix_agent2' | cut -c1-110"
H=$(zabbix_get -s 127.0.0.1 -k helios.suivi.http 2>&1); A=$(zabbix_get -s 127.0.0.1 -k helios.suivi.age 2>&1)
if [[ $H != 200 || ! $A =~ ^[0-9]+$ ]]; then          # diagnostic SELinux si une sonde echoue
    run "echo \"sondes en echec : http=$H age=$A\" ; ausearch -m AVC -ts recent -i 2>/dev/null | grep -i zabbix | tail -4 | cut -c1-124"
    if ausearch -m AVC -ts recent 2>/dev/null | grep -qi zabbix; then
        run "cd $CFG && ausearch -m AVC -ts recent | audit2allow -M helios-zabbix >/dev/null && semodule -i helios-zabbix.pp && echo 'module SELinux helios-zabbix installe' && cat helios-zabbix.te | grep allow"
        systemctl restart zabbix-agent2 ; sleep 3
    fi
fi
run "zabbix_get -s 127.0.0.1 -k helios.suivi.http ; zabbix_get -s 127.0.0.1 -k helios.suivi.age"
run "runuser -u zabbix -- stat -c '%n : %s octets, modifie le %y' $WWW/etat.json ; runuser -u zabbix -- ls $WWW"
run "systemctl is-active zabbix-agent2 sysstat-collect.timer ; systemctl is-enabled zabbix-agent2 ; sar -u 1 2 | tail -3"
pause

######################################################################## E9
ecran 10-E9-sauvegarde.txt "E9 — Sauvegarde"
install -d -m 0750 -o helios -g helios /srv/helios/archives
install -d -m 0700 -o root -g root "$ARCH"
install -m 0750 -o root -g root "$SRC_CFG/helios-suivi-backup.sh" $SB/helios-suivi-backup.sh
install -m 0750 -o root -g root "$SRC_CFG/helios-suivi-audit.sh"  $SB/helios-suivi-audit.sh
for u in helios-suivi-backup.service helios-suivi-backup.timer; do install -m 0644 -o root -g root "$SRC_CFG/$u" "$SD/$u"; done
systemctl daemon-reload ; systemctl enable --now helios-suivi-backup.timer &>/dev/null
run "ls -ld /srv/helios/archives $ARCH"
run "systemctl start helios-suivi-backup.service ; systemctl show -p Result helios-suivi-backup.service ; journalctl -t helios-suivi-backup -n 3 --no-pager -o cat"
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

######################################################################## Mesure
ecran 12-mesure-charge.txt "Mesure sous charge : 2000 requetes sur etat.json"
CG=/sys/fs/cgroup/system.slice/helios-suivi.service
run "systemctl show -p CPUUsageNSec -p MemoryCurrent helios-suivi.service ; grep -E 'nr_throttled|throttled_usec' $CG/cpu.stat"
C0=$(systemctl show -p CPUUsageNSec --value helios-suivi.service)
sar -u 1 > "$PRV/12-sar-u.txt" 2>&1 & SP=$!
t0=$(date +%s.%N)
for i in $(seq 2000); do curl -s -o /dev/null http://127.0.0.1:8080/etat.json; done
t1=$(date +%s.%N)
kill -INT $SP ; wait $SP 2>/dev/null
C1=$(systemctl show -p CPUUsageNSec --value helios-suivi.service)
run "echo \"2000 requetes en $(calc "$t1 - $t0") s\" ; systemctl show -p CPUUsageNSec -p MemoryCurrent helios-suivi.service ; grep -E 'nr_throttled|throttled_usec' $CG/cpu.stat"
run "echo \"CPU du portail pendant la charge : $(calc "($C1 - $C0) / 10000000 / ($t1 - $t0)") % d un coeur (quota : 50 %)\""
run "head -3 $PRV/12-sar-u.txt | tail -1 ; grep -E '^Average' $PRV/12-sar-u.txt ; sort -k3 -n -r $PRV/12-sar-u.txt | grep -E '^[0-9]' | head -1 | sed 's/^/pic : /'"
pause

######################################################################## E10
ecran 13-E10-audit.txt "E10 (bonus) — Audit de conformite"
$SB/helios-suivi-backup.sh                         # derniere archive : contient aussi le script d'audit
printf '$ %s\n' "$SB/helios-suivi-audit.sh ; echo rc=\$?" | tee -a "$PRV/$F"
$SB/helios-suivi-audit.sh | tee "$PRV/audit.txt" | tee -a "$PRV/$F" ; echo "rc=${PIPESTATUS[0]}" | tee -a "$PRV/audit.txt" "$PRV/$F"
run "systemctl stop helios-suivi.service ; $SB/helios-suivi-audit.sh | grep -E 'KO|Bilan' | cut -c1-124 ; echo \"rc=\${PIPESTATUS[0]}   (portail arrete)\" ; systemctl start helios-suivi.service"
pause

######################################################################## Rendu
for f in helios-suivi.service helios-suivi-publish.service helios-suivi-publish.timer helios-suivi-backup.service helios-suivi-backup.timer; do cp "$SD/$f" "$CFG/"; done
cp $SB/helios-suivi-publish.sh $SB/helios-suivi-backup.sh $SB/helios-suivi-audit.sh /etc/sudoers.d/92-helios-suivi \
   /etc/zabbix/zabbix_agent2.d/helios-suivi.conf "$CFG/"
getfacl -R -p "$WWW" > "$CFG/getfacl-www.txt" 2>/dev/null
firewall-cmd --zone=internal --list-all > "$CFG/firewall-internal.txt"
cp -f "$P_DIR"/*.sh "$OUT/" 2>/dev/null
ecran 14-fin.txt "Fin de la partie 1"
info "Rendu prepare dans $OUT (configs/ et preuves/)."
info "Il reste a redemarrer pour verifier que tout est persistant, puis : bash /tmp/p/p2.sh"
read -rp "Redemarrer srv-core maintenant ? [o/N] " r </dev/tty
[[ $r == [oO]* ]] && systemctl reboot
