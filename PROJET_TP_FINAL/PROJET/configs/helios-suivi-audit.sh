#!/usr/bin/bash
# helios-suivi-audit.sh — audit de conformite du portail de suivi (exigences E1 a E9).
# Lance en root, il NE MODIFIE RIEN : il ne fait que lire et interroger.
# Une ligne [OK]/[KO] par exigence, puis « Bilan : n/9 ». Code retour 0 si et seulement si 9/9.
# Un controle qui ne peut pas s'executer (commande absente, fichier illisible) compte comme [KO].
set -uo pipefail
export LC_ALL=C

readonly WWW=/srv/helios/suivi/www
readonly ARCH=/srv/helios/archives/suivi
readonly SUDOF=/etc/sudoers.d/92-helios-suivi
readonly ZCONF=/etc/zabbix/zabbix_agent2.d/helios-suivi.conf

[[ $EUID -eq 0 ]] || { echo "[KO] l'audit doit etre lance en root"; echo "Bilan : 0/9"; exit 1; }

total=0; okc=0; RAISONS=()
# echec <texte> : note une non-conformite pour l'exigence en cours
echec() { RAISONS+=("$1"); }
# outil <cmd>... : verifie que les commandes existent, sinon non-conformite
outil() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || echec "commande absente : $c"; done; }
# bilan <id> <libelle> : affiche la ligne de l'exigence
bilan() {
    total=$((total + 1))
    if ((${#RAISONS[@]} == 0)); then
        okc=$((okc + 1)); printf '[OK] %s — %s\n' "$1" "$2"
    else
        local IFS='; '; printf '[KO] %s — %s : %s\n' "$1" "$2" "${RAISONS[*]}"
    fi
    RAISONS=()
}
champ() { getent passwd "$1" | cut -d: -f"$2"; }

########## E1 — Comptes et groupe
outil getent id
[[ $(getent group suivi | cut -d: -f3) == 5003 ]] || echec "groupe suivi absent ou gid != 5003"
if getent passwd lea >/dev/null; then
    [[ $(champ lea 3) == 5104 ]] || echec "uid de lea != 5104"
    [[ $(id -gn lea 2>/dev/null) == suivi ]] || echec "groupe primaire de lea != suivi"
    [[ $(champ lea 5) == "Lea Fabre - responsable suivi des tournees" ]] || echec "commentaire de lea incorrect"
    sh=$(awk -F: '$1=="lea"{print $4":"$5":"$6":"$7}' /etc/shadow 2>/dev/null)
    [[ $sh == "1:90:14:7" ]] || echec "politique de mot de passe de lea (min:max:alerte:inactif=$sh, attendu 1:90:14:7)"
    id -nG lea 2>/dev/null | tr ' ' '\n' | grep -qxE 'wheel|ssh-admins' && echec "lea est dans wheel ou ssh-admins"
else
    echec "compte lea absent"
fi
if getent passwd helios-suivi >/dev/null; then
    (( $(champ helios-suivi 3) < 1000 )) || echec "helios-suivi n'est pas un compte systeme"
    [[ $(champ helios-suivi 7) == */nologin || $(champ helios-suivi 7) == /bin/false ]] || echec "helios-suivi a un shell de connexion"
    [[ $(champ helios-suivi 6) == /srv/helios/suivi ]] || echec "home de helios-suivi != /srv/helios/suivi"
    [[ -e /home/helios-suivi ]] && echec "/home/helios-suivi existe"
else
    echec "compte helios-suivi absent"
fi
bilan E1 "Comptes et groupe"

########## E2 — www : setgid et ACL
outil getfacl runuser stat
if [[ -d $WWW ]]; then
    [[ $(stat -c '%U:%G %a' "$WWW") == "root:suivi 2770" ]] || echec "www est $(stat -c '%U:%G %a' "$WWW"), attendu root:suivi 2770"
    acl=$(getfacl -p "$WWW" 2>/dev/null) || echec "getfacl impossible sur www"
    grep -qx 'user:helios-suivi:rwx' <<<"$acl"            || echec "ACL helios-suivi:rwx absente"
    grep -qx 'user:zabbix:--x' <<<"$acl"                  || echec "ACL zabbix:--x absente"
    grep -qx 'other::---' <<<"$acl"                       || echec "les autres ont des droits sur www"
    grep -qE '^default:user:helios-suivi:r' <<<"$acl"     || echec "ACL par defaut helios-suivi absente"
    grep -qx 'default:group::rw-' <<<"$acl" || grep -qx 'default:group::rwx' <<<"$acl" || echec "ACL par defaut groupe rw absente"
    grep -qx 'default:other::---' <<<"$acl"               || echec "ACL par defaut other::--- absente"
    runuser -u zabbix -- ls "$WWW" >/dev/null 2>&1        && echec "zabbix peut lister www"
    runuser -u zabbix -- stat "$WWW/etat.json" >/dev/null 2>&1 || echec "zabbix ne peut pas faire stat sur etat.json"
    if [[ -f $WWW/index.html ]]; then
        [[ $(stat -c %U:%G "$WWW/index.html") == lea:suivi ]] || echec "index.html n'appartient pas a lea:suivi"
        runuser -u helios-suivi -- cat "$WWW/index.html" >/dev/null 2>&1 || echec "helios-suivi ne lit pas index.html"
        getent passwd nadia >/dev/null && runuser -u nadia -- cat "$WWW/index.html" >/dev/null 2>&1 && echec "nadia lit index.html"
    else
        echec "index.html absent"
    fi
else
    echec "$WWW absent"
fi
bilan E2 "Repertoire publie (setgid + ACL)"

########## E3 — Script de publication et etat.json
outil python3
P=/usr/local/sbin/helios-suivi-publish.sh
[[ -x $P ]] || echec "$P absent ou non executable"
if [[ -r $WWW/etat.json ]]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [d[k] for k in ("genere","hote","derniere_mesure","charge_1min","mem_dispo_ko","mesures")]' \
        "$WWW/etat.json" 2>/dev/null || echec "etat.json invalide ou champ manquant"
    age=$(( $(date +%s) - $(stat -c %Y "$WWW/etat.json") ))
    (( age < 300 )) || echec "etat.json vieux de ${age} s (> 5 min)"
else
    echec "etat.json absent ou illisible"
fi
bilan E3 "Publication de etat.json"

########## E4 — Units systemd
outil systemctl curl systemd-analyze
systemctl is-active -q helios-suivi.service || echec "portail helios-suivi.service arrete"
systemctl is-enabled -q helios-suivi.service || echec "portail non active au boot"
[[ $(systemctl show -p User --value helios-suivi.service) == helios-suivi ]] || echec "le portail ne tourne pas en helios-suivi"
[[ $(systemctl show -p Restart --value helios-suivi.service) =~ ^(on-failure|always|on-abnormal)$ ]] || echec "pas de redemarrage automatique"
[[ $(systemctl show -p MemoryMax --value helios-suivi.service) == 134217728 ]] || echec "MemoryMax != 128M"
[[ $(systemctl show -p CPUQuotaPerSecUSec --value helios-suivi.service) == 500ms ]] || echec "CPUQuota != 50%"
systemctl list-dependencies --plain helios.target 2>/dev/null | grep -q 'helios-suivi.service' || echec "portail non rattache a helios.target"
score=$(systemd-analyze security --no-pager helios-suivi.service 2>/dev/null | grep -oP 'Overall exposure level for \S+: \K[0-9.]+')
[[ -n $score ]] && awk -v s="$score" 'BEGIN{exit !(s <= 4.0)}' || echec "exposition ${score:-inconnue} > 4.0"
for u in / /etat.json; do
    c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:8080$u")
    [[ $c == 200 ]] || echec "GET $u -> $c"
done
systemctl is-active -q helios-suivi-publish.timer || echec "helios-suivi-publish.timer inactif"
[[ $(systemctl show -p User --value helios-suivi-publish.service) == helios-suivi ]] || echec "publication pas en helios-suivi"
bilan E4 "Units systemd (portail durci, publication)"

########## E5 — Delegation sudo
outil visudo sudo
if [[ -f $SUDOF ]]; then
    visudo -c -q -f "$SUDOF" >/dev/null 2>&1 || echec "$SUDOF invalide"
    [[ $(stat -c '%U:%G %a' "$SUDOF") == "root:root 440" ]] || echec "$SUDOF n'est pas 0440 root:root"
    grep -v '^[[:space:]]*#' "$SUDOF" | grep -q 'NOPASSWD' && echec "NOPASSWD present"
    grep -v '^[[:space:]]*#' "$SUDOF" | grep -q '\*' && echec "joker * dans $SUDOF"
else
    echec "$SUDOF absent"
fi
if getent passwd lea >/dev/null; then
    sudo -l -U lea /usr/bin/systemctl restart helios-suivi.service >/dev/null 2>&1 || echec "lea ne peut pas redemarrer le portail"
    sudo -l -U lea /usr/bin/journalctl -u helios-suivi.service -n 100 --no-pager >/dev/null 2>&1 || echec "lea ne peut pas lire le journal du portail"
    for interdit in "/usr/bin/systemctl restart sshd" "/usr/bin/systemctl restart sshd.service" \
                    "/usr/bin/journalctl --vacuum-time=1s" "/usr/bin/systemctl status helios-suivi.service" \
                    "/usr/bin/bash"; do
        # shellcheck disable=SC2086
        sudo -l -U lea $interdit >/dev/null 2>&1 && echec "lea peut lancer : $interdit"
    done
fi
bilan E5 "Delegation sudo"

########## E6 — Pare-feu
outil firewall-cmd
if firewall-cmd -q --state 2>/dev/null; then
    [[ $(firewall-cmd --get-default-zone) == drop ]] || echec "zone par defaut != drop"
    firewall-cmd -q --zone=internal --query-port=8080/tcp || echec "8080/tcp absent de internal (runtime)"
    firewall-cmd -q --permanent --zone=internal --query-port=8080/tcp || echec "8080/tcp absent de internal (permanent)"
    for z in $(firewall-cmd --get-zones); do
        [[ $z == internal ]] && continue
        for mode in "" "--permanent"; do
            # shellcheck disable=SC2086
            firewall-cmd $mode --zone="$z" --list-all 2>/dev/null | grep -q '8080' && echec "8080 present dans la zone $z ${mode:-(runtime)}"
        done
    done
    firewall-cmd --permanent --zone=internal --list-rich-rules 2>/dev/null | grep -q 8080 && echec "8080 dans une regle riche"
else
    echec "firewalld arrete"
fi
bilan E6 "Pare-feu (8080 seulement dans internal)"

########## E7 — Non-regression securite
outil sshd
t=$(sshd -T 2>/dev/null)
grep -qx 'port 2242' <<<"$t"                    || echec "sshd : port != 2242"
grep -qx 'permitrootlogin no' <<<"$t"           || echec "sshd : root autorise"
grep -qx 'passwordauthentication no' <<<"$t"    || echec "sshd : mots de passe autorises"
grep -qx 'allowgroups ssh-admins' <<<"$t"       || echec "sshd : allowgroups != ssh-admins"
systemctl is-active -q helios-watch-auth.timer  || echec "helios-watch-auth.timer inactif"
[[ -d /var/log/journal/$(cat /etc/machine-id 2>/dev/null) ]] || echec "journal non persistant"
getenforce 2>/dev/null | grep -qx Enforcing     || echec "SELinux n'est pas en Enforcing"
bilan E7 "Non-regression de la securite"

########## E8 — Supervision
outil zabbix_get
systemctl is-active -q zabbix-agent2   || echec "zabbix-agent2 inactif"
systemctl is-enabled -q zabbix-agent2  || echec "zabbix-agent2 non active au boot"
systemctl is-active -q sysstat-collect.timer || echec "sysstat-collect.timer inactif"
[[ -r $ZCONF ]] && grep -q '^UserParameter=helios.suivi.http,' "$ZCONF" && grep -q '^UserParameter=helios.suivi.age,' "$ZCONF" || echec "sondes absentes de $ZCONF"
if command -v zabbix_get >/dev/null; then
    h=$(zabbix_get -s 127.0.0.1 -k helios.suivi.http 2>/dev/null)
    a=$(zabbix_get -s 127.0.0.1 -k helios.suivi.age 2>/dev/null)
    [[ $h == 200 ]] || echec "helios.suivi.http = ${h:-rien}"
    [[ $a =~ ^[0-9]+$ ]] && (( a < 300 )) || echec "helios.suivi.age = ${a:-rien}"
fi
bilan E8 "Supervision Zabbix + sar"

########## E9 — Sauvegarde
outil sha256sum tar
[[ $(stat -c '%U:%G %a' /srv/helios/archives 2>/dev/null) == "helios:helios 750" ]] || echec "/srv/helios/archives n'est pas helios:helios 0750"
derniere=$(ls -1 "$ARCH"/suivi-*.tar.gz 2>/dev/null | sort | tail -1)
if [[ -n $derniere ]]; then
    ( cd "$ARCH" && sha256sum --quiet -c "$(basename "$derniere").sha256" ) >/dev/null 2>&1 || echec "empreinte invalide pour $(basename "$derniere")"
    n=$(ls -1 "$ARCH"/suivi-*.tar.gz | wc -l); (( n <= 7 )) || echec "$n archives (> 7)"
    lst=$(tar -tzf "$derniere" 2>/dev/null) || echec "archive illisible"
    for p in srv/helios/suivi/www/index.html etc/systemd/system/helios-suivi.service etc/sudoers.d/92-helios-suivi \
             etc/zabbix/zabbix_agent2.d/helios-suivi.conf usr/local/sbin/helios-suivi-publish.sh usr/local/sbin/helios-suivi-backup.sh; do
        grep -qx "$p" <<<"$lst" || echec "$p absent de l'archive"
    done
else
    echec "aucune sauvegarde dans $ARCH"
fi
systemctl is-enabled -q helios-suivi-backup.timer || echec "helios-suivi-backup.timer non active"
[[ $(systemctl show -p Persistent --value helios-suivi-backup.timer) == yes ]] || echec "timer de sauvegarde sans rattrapage"
bilan E9 "Sauvegarde et restauration"

echo "Bilan : $okc/$total"
(( okc == total ))
