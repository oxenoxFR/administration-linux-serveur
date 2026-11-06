#!/usr/bin/bash
# helios-watchauth.sh — detecte les echecs d'authentification SSH repetes et bloque la source.
# Fenetre glissante de 10 min ; au-dela de 5 echecs, l'adresse rejoint l'ipset helios-blacklist.
# Sortie : 0 nominal · 1 erreur interne · 2 une autre instance tourne deja
set -euo pipefail
IFS=$'\n\t'

readonly TAG=helios-watch-auth
readonly LOCK=/run/lock/helios-watchauth.lock
readonly IPSET=helios-blacklist
readonly SEUIL=5
readonly FENETRE="10 min ago"
readonly ETAT=/var/lib/helios/blocked.txt
readonly LISTE_BLANCHE=("192.168.56.1" "127.0.0.1")   # poste du formateur + boucle locale

log() { logger -t "$TAG" -p "authpriv.${1}" -- "$2" ; }
die() { log err "$1" ; exit "${2:-1}" ; }
trap 'die "interrompu par signal" 1' INT TERM

exec 9>"$LOCK"
flock -n 9 || { log warning "une autre instance tourne deja" ; exit 2 ; }

command -v firewall-cmd >/dev/null || die "firewall-cmd absent" 1
install -d -m 0750 "$(dirname "$ETAT")" ; touch "$ETAT"

# Adresses sources des echecs : utilisateur inconnu, mauvais mot de passe/cle, trop d'essais
mapfile -t COMPTES < <(
    journalctl -u sshd --since "$FENETRE" -o cat --no-pager 2>/dev/null \
    | grep -oP '(Invalid user \S* from|Failed \S+ for (invalid user )?\S+ from|maximum authentication attempts exceeded for .* from) \K[0-9.]+' \
    | sort | uniq -c | awk -v s="$SEUIL" '$1 > s {print $2" "$1}'
)

nouveaux=0
for ligne in "${COMPTES[@]}"; do
    ip="${ligne%% *}" ; nb="${ligne##* }"
    for ok in "${LISTE_BLANCHE[@]}"; do [[ $ip == "$ok" ]] && { log info "$ip ignoree (liste blanche, $nb echecs)" ; continue 2 ; } ; done
    if grep -qxF "$ip" "$ETAT" || firewall-cmd -q --ipset="$IPSET" --query-entry="$ip"; then
        continue                                  # idempotence : deja bloquee, pas de 2e alerte
    fi
    firewall-cmd -q --ipset="$IPSET" --add-entry="$ip"
    firewall-cmd -q --permanent --ipset="$IPSET" --add-entry="$ip"
    echo "$ip" >> "$ETAT"
    log warning "BLOCAGE $ip : $nb echecs SSH en 10 min"
    nouveaux=$((nouveaux + 1))
done
log info "analyse terminee : ${#COMPTES[@]} source(s) au-dessus du seuil, $nouveaux nouveau(x) blocage(s)"
exit 0
