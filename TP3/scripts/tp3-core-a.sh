#!/usr/bin/bash
# TP3 — partie A sur srv-core (root) : pare-feu, durcissement SSH, journald, auditd, bonus -e 2.
# Se termine par un redemarrage (necessaire pour journalctl --list-boots).
# Les etapes cote srv-edge sont demandees par le script au bon moment (pause).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root; exiger_hote srv-core

ADMIN_USER="${ADMIN_USER:-david}"     # ton compte (l'enonce dit « sysops »)
AK="/home/$ADMIN_USER/.ssh/authorized_keys"

titre "Verification de securite avant de commencer"
if [[ ! -s $AK ]]; then
    ko "$AK est vide ou absent : sans cle, tu perdrais l'acces SSH apres le durcissement."
    info "Fais d'abord l'etape 0 (cle depuis ton PC) et l'etape 1 (tp3-edge.sh avant), puis relance."
    exit 1
fi
ok "$(grep -c . "$AK") cle(s) autorisee(s) pour $ADMIN_USER"
rpm -q policycoreutils-python-utils &>/dev/null || dnf -y -q install policycoreutils-python-utils
rpm -q nmap-ncat &>/dev/null || dnf -y -q install nmap-ncat

########################################################################
titre "MISSION 1 — Pare-feu firewalld segmente par zone"
########################################################################
F=m1-etat-initial.txt; : > "$CAP/$F"
run $F "systemctl unmask firewalld 2>/dev/null ; systemctl enable --now firewalld"
run $F "firewall-cmd --state ; firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"
run $F "nmcli -g NAME con show | while read -r c ; do printf '%s : %s\n' \"\$c\" \"\$(nmcli -g connection.zone con show \"\$c\")\" ; done"

F=m1-zones.txt; : > "$CAP/$F"
NATCON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2=="enp0s3"{print $1}')
ADMCON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2=="enp0s8"{print $1}')
info "Connexion NAT : « $NATCON » ; connexion administration : « $ADMCON » (l'enonce l'appelle « admin »)"
valeur NATCON "$NATCON"; valeur ADMCON "$ADMCON"
run $F "nmcli con mod '$NATCON' connection.zone drop"
run $F "nmcli con mod '$ADMCON' connection.zone work"
run $F "nmcli con mod bond0 connection.zone internal"
run $F "nmcli con mod bond0.42 connection.zone internal"
for c in "$NATCON" "$ADMCON" bond0 bond0.42; do nmcli con up "$c" >/dev/null; done
run $F "firewall-cmd --set-default-zone=drop"
for s in dhcpv6-client cockpit; do firewall-cmd -q --permanent --zone=work --remove-service=$s 2>/dev/null; done
run $F "firewall-cmd --permanent --zone=work --add-service=ssh ; firewall-cmd --permanent --zone=work --add-source=192.168.56.0/24"
for s in mdns samba-client cockpit dhcpv6-client; do firewall-cmd -q --permanent --zone=internal --remove-service=$s 2>/dev/null; done
run $F "firewall-cmd --permanent --zone=internal --add-service=ssh ; firewall-cmd --permanent --zone=internal --add-port=10051/tcp"
run $F "firewall-cmd --reload"
run $F "firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"

titre "1.4 — Regles riches, ipset, journalisation"
F=m1-regles-riches.txt; : > "$CAP/$F"
R_SSH='rule service name="ssh" log prefix="SSH-NEW " level="info" limit value="3/m" accept limit value="6/m"'
firewall-cmd -q --permanent --zone=work --remove-service=ssh
firewall-cmd -q --permanent --zone=work --query-rich-rule="$R_SSH" || firewall-cmd -q --permanent --zone=work --add-rich-rule="$R_SSH"
firewall-cmd -q --permanent --zone=work --add-rich-rule='rule port port="10051" protocol="tcp" reject' 2>/dev/null
firewall-cmd -q --permanent --get-ipsets | grep -qw helios-blacklist || \
  run $F "firewall-cmd --permanent --new-ipset=helios-blacklist --type=hash:ip --option=family=inet --option=hashsize=4096 --option=maxelem=65536"
for z in work internal; do
  firewall-cmd -q --permanent --zone=$z --add-rich-rule='rule source ipset="helios-blacklist" drop' 2>/dev/null
done
run $F "firewall-cmd --set-log-denied=unicast"
run $F "firewall-cmd --check-config && firewall-cmd --reload"
run $F "firewall-cmd --get-ipsets ; firewall-cmd --zone=work --list-rich-rules"
run $F "firewall-cmd --zone=work --list-all ; firewall-cmd --zone=internal --list-all"
run $F "nft list tables"
run $F "nft list chain inet firewalld filter_IN_work"
run $F "nft list set inet firewalld helios-blacklist"
run $F "iptables -S | head -5"

pause "Sur srv-edge (en tant que $ADMIN_USER) lance :  bash ~/TP3/scripts/tp3-edge.sh parefeu   puis reviens ici"
F=m1-traces.txt; : > "$CAP/$F"
run $F "journalctl -k -g 'SSH-NEW' -n 20 --no-pager"
run $F "journalctl -k -g 'REJECT|DROP' -n 20 --no-pager"
N=$(journalctl -k -g 'SSH-NEW' --no-pager -q | grep -c SSH-NEW); valeur SSHNEW "$N"
(( N > 0 )) && ok "$N lignes SSH-NEW dans le journal noyau" || ko "Aucune ligne SSH-NEW"

########################################################################
titre "MISSION 2 — Durcissement de sshd"
########################################################################
F=m2-preparation.txt; : > "$CAP/$F"
getent group ssh-admins >/dev/null || groupadd -r ssh-admins
run $F "usermod -aG ssh-admins $ADMIN_USER ; usermod -aG ssh-admins julien ; getent group ssh-admins"
chmod 700 "/home/$ADMIN_USER/.ssh"; chmod 600 "$AK"; chown -R "$ADMIN_USER:" "/home/$ADMIN_USER/.ssh"; restorecon -R "/home/$ADMIN_USER/.ssh"
run $F "for k in /etc/ssh/ssh_host_*_key.pub ; do ssh-keygen -lf \"\$k\" ; done"
run $F "ls -lZ $AK"

F=m2-sshd.txt; : > "$CAP/$F"
install -m 0644 "$CFG/issue.net" /etc/issue.net
install -m 0600 "$CFG/10-helios-hardening.conf" /etc/ssh/sshd_config.d/10-helios-hardening.conf
# Garde-fou : sshd doit pouvoir ecouter sur 10.42.0.10 meme si le bond n'est pas encore pret au boot
# (NetworkManager-wait-online a ete masque au TP1).
echo 'net.ipv4.ip_nonlocal_bind = 1' > /etc/sysctl.d/90-helios-sshd.conf; sysctl -q -p /etc/sysctl.d/90-helios-sshd.conf
run $F "sshd -t && echo 'syntaxe OK'" || { ko "sshd -t echoue : retour arriere"; rm -f /etc/ssh/sshd_config.d/10-helios-hardening.conf; exit 1; }

titre "2.3 — Algorithmes et crypto-policies"
run $F "update-crypto-policies --show ; head -6 /etc/ssh/sshd_config.d/50-redhat.conf"
run $F "update-crypto-policies --set DEFAULT:NO-SHA1"
install -m 0600 "$CFG/05-helios-crypto.conf" /etc/ssh/sshd_config.d/05-helios-crypto.conf
run $F "sshd -t && echo 'syntaxe OK'"

titre "2.4 — Changement de port : SELinux et pare-feu"
run $F "semanage port -a -t ssh_port_t -p tcp 2242 2>/dev/null || semanage port -m -t ssh_port_t -p tcp 2242"
run $F "semanage port -l | grep '^ssh_port_t'"
R_2242='rule port port="2242" protocol="tcp" log prefix="SSH-NEW " level="info" limit value="3/m" accept limit value="6/m"'
firewall-cmd -q --permanent --zone=work --query-rich-rule="$R_2242" || firewall-cmd -q --permanent --zone=work --add-rich-rule="$R_2242"
firewall-cmd -q --permanent --zone=work --remove-rich-rule="$R_SSH" 2>/dev/null
firewall-cmd -q --permanent --zone=internal --add-port=2242/tcp
firewall-cmd -q --permanent --zone=internal --remove-service=ssh
run $F "firewall-cmd --reload ; firewall-cmd --zone=work --list-rich-rules"
run $F "systemctl restart sshd ; sleep 2 ; ss -ltnp | grep sshd"
run $F "journalctl -u sshd -n 20 --no-pager"
run $F "sshd -T | grep -iE '^(ciphers|kexalgorithms|macs|hostkeyalgorithms)'"
run $F "sshd -T | grep -iE 'permitrootlogin|passwordauthentication|allowgroups|maxauthtries|^port |loglevel'"
systemctl is-active -q sshd && ok "sshd tourne sur le port 2242" || ko "sshd ne tourne pas — utilise la console VirtualBox"
echo
info "IMPORTANT : ta session actuelle reste ouverte. Teste dans un AUTRE onglet de ton PC :"
info "    ssh -p 2242 $ADMIN_USER@192.168.56.10"
pause "Quand la connexion par cle sur le port 2242 marche depuis ton PC, lance sur srv-edge :  bash ~/TP3/scripts/tp3-edge.sh ssh   puis reviens ici"
F=m2-traces-tests.txt; : > "$CAP/$F"
run $F "journalctl -u sshd --since '-15min' -o short-iso --no-pager | tail -60"

########################################################################
titre "MISSION 3.1 — journald persistant"
########################################################################
F=m3-journald.txt; : > "$CAP/$F"
install -d /etc/systemd/journald.conf.d
install -m 0644 "$CFG/50-helios.conf" /etc/systemd/journald.conf.d/50-helios.conf
run $F "systemctl restart systemd-journald ; journalctl --flush"
run $F "ls -ld /var/log/journal/\$(cat /etc/machine-id)"
run $F "journalctl --disk-usage ; journalctl --verify 2>&1 | tail -5"

########################################################################
titre "MISSION 3.3 — auditd"
########################################################################
F=m3-auditd.txt; : > "$CAP/$F"
run $F "systemctl enable --now auditd"
install -m 0640 "$CFG/90-helios.rules" /etc/audit/rules.d/90-helios.rules
run $F "augenrules --load ; auditctl -l ; auditctl -s | head -5"
touch /etc/sudoers.d/test-audit && rm -f /etc/sudoers.d/test-audit
su - julien -c '/usr/local/bin/helios-lastlog >/dev/null'
su - julien -c 'sudo -n systemctl status helios-collect.service >/dev/null' 2>/dev/null
sleep 1
run $F "ausearch -k sudoers -i | tail -20"
run $F "ausearch -k helios-setgid -i | tail -10"
run $F "ausearch -k privesc -i --start today | tail -20"
run $F "ausearch -m USER_LOGIN,USER_AUTH --start today -i | tail -20"
run $F "aureport --auth --summary -i ; aureport --failed --summary -i ; aureport -k --summary -i"

titre "BONUS 1 — Regles auditd immuables (-e 2)"
F=bonus-immuable.txt; : > "$CAP/$F"
grep -qx -- '-e 2' /etc/audit/rules.d/90-helios.rules || echo '-e 2' >> /etc/audit/rules.d/90-helios.rules
run $F "augenrules --load ; auditctl -s | grep enabled"
run $F "auditctl -D"
sed -i '/^-e 2$/d' /etc/audit/rules.d/90-helios.rules
run $F "tail -2 /etc/audit/rules.d/90-helios.rules"
info "-e 2 retire du fichier : au prochain demarrage, les regles redeviennent modifiables (enabled 1)."

titre "Fin de la partie A"
firewall-cmd --list-all-zones > "$CFG/zones.txt"
info "Le redemarrage est demande par l'enonce (journalctl --list-boots >= 2)."
info "Apres le reboot, reconnecte-toi avec :  ssh -p 2242 $ADMIN_USER@192.168.56.10   puis :  sudo -i ; cd /root/TP3/scripts ; bash tp3-core-b.sh"
confirmer "Redemarrer srv-core maintenant ?" && systemctl reboot
