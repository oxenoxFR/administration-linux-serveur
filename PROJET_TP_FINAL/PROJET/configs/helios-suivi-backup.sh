#!/usr/bin/bash
# helios-suivi-backup.sh — sauvegarde de tout ce qu'il faut pour reconstruire le portail de suivi.
# Produit /srv/helios/archives/suivi/suivi-AAAAMMJJ-HHMMSS.tar.gz (+ .sha256), garde les 7 dernieres.
# Sortie : 0 succes · 1 erreur interne · 2 une autre instance tourne · 3 prerequis manquant
set -euo pipefail
IFS=$'\n\t'

readonly TAG=helios-suivi-backup
readonly DEST=/srv/helios/archives/suivi
readonly GARDER=7
readonly LOCK=/run/lock/helios-suivi-backup.lock
# Chemins relatifs a / (tar -C /) : le service, ses units, sudoers, la sonde Zabbix et les scripts
readonly CONTENU=(
    srv/helios/suivi
    etc/systemd/system/helios-suivi.service
    etc/systemd/system/helios-suivi-publish.service
    etc/systemd/system/helios-suivi-publish.timer
    etc/systemd/system/helios-suivi-backup.service
    etc/systemd/system/helios-suivi-backup.timer
    etc/sudoers.d/92-helios-suivi
    etc/zabbix/zabbix_agent2.d/helios-suivi.conf
    usr/local/sbin/helios-suivi-publish.sh
    usr/local/sbin/helios-suivi-backup.sh
)

TMP=""
# socket du journal designee explicitement : /dev/log peut manquer sous PrivateDevices=
log() { logger -u /run/systemd/journal/dev-log -t "$TAG" -p "daemon.${1}" -- "$2" || true ; }
die() { log err "$1" ; exit "${2:-1}" ; }
cleanup() { local rc=$? ; [[ -n $TMP && -e $TMP ]] && rm -f -- "$TMP"
            log info "fin d'execution rc=${rc}" ; return 0 ; }
trap cleanup EXIT
trap 'die "interrompu par signal" 1' INT TERM

exec 9>"$LOCK"
flock -n 9 || { log warning "une autre instance tourne deja" ; exit 2 ; }

# Prerequis (code 3)
[[ $EUID -eq 0 ]] || die "doit tourner en root (lecture de sudoers)" 3
for c in tar gzip sha256sum; do command -v "$c" >/dev/null || die "$c absent" 3; done
[[ -d $DEST && -w $DEST ]] || die "destination absente ou non inscriptible : $DEST" 3
liste=()
for p in "${CONTENU[@]}"; do
    if [[ -e /$p ]]; then liste+=("$p"); else log warning "absent, non sauvegarde : /$p"; fi
done
[[ -d /srv/helios/suivi ]] || die "/srv/helios/suivi absent : rien a sauvegarder" 3
[[ -f /usr/local/sbin/helios-suivi-audit.sh ]] && liste+=(usr/local/sbin/helios-suivi-audit.sh)

log info "demarrage (${#liste[@]} elements)"
nom="suivi-$(date +%Y%m%d-%H%M%S).tar.gz"
TMP=$(mktemp "$DEST/.${nom}.XXXXXX")
# --acls et --xattrs : on garde les ACL de www et les contextes SELinux (--selinux)
tar --acls --xattrs --selinux -czpf "$TMP" -C / "${liste[@]}" || die "echec de tar" 1
gzip -t "$TMP" || die "archive corrompue" 1
chmod 0600 -- "$TMP"
mv -f -- "$TMP" "$DEST/$nom" ; TMP=""
( cd "$DEST" && sha256sum -- "$nom" > "$nom.sha256" && chmod 0600 -- "$nom.sha256" \
  && sha256sum --quiet -c -- "$nom.sha256" ) || die "empreinte invalide pour $nom" 1
log info "archive $DEST/$nom ($(du -h "$DEST/$nom" | cut -f1), empreinte verifiee)"

# Retention : on ne garde que les $GARDER plus recentes (le nom contient la date, tri lexical = chronologique)
mapfile -t vieilles < <(cd "$DEST" && ls -1 suivi-*.tar.gz 2>/dev/null | sort -r | tail -n +$((GARDER + 1)))
for v in "${vieilles[@]}"; do
    rm -f -- "$DEST/$v" "$DEST/$v.sha256" && log info "purge : $v"
done
exit 0
