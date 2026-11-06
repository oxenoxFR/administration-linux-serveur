#!/usr/bin/bash
# helios-suivi-publish.sh — publie l'etat du collecteur de telemetrie dans www/etat.json.
# Lit la derniere ligne de telemetry.csv (horodatage,charge_1min,mem_dispo_ko).
# Sortie : 0 succes · 1 erreur interne (ligne invalide...) · 2 une autre instance tourne · 3 prerequis manquant
set -euo pipefail
IFS=$'\n\t'

readonly TAG=helios-suivi-publish
readonly SRC="${HELIOS_TELEMETRY:-/var/lib/helios/telemetry.csv}"   # surcharge possible pour les tests
readonly WWW=/srv/helios/suivi/www
readonly DEST="$WWW/etat.json"
# Verrou : flock sur le script lui-meme, ouvert en LECTURE. Aucune ecriture necessaire,
# donc ca marche aussi sous ProtectSystem=strict (ou /run/lock n'est pas inscriptible).
readonly LOCK="$(readlink -f "${BASH_SOURCE[0]}")"

TMP=""
# socket du journal designee explicitement : /dev/log peut manquer sous PrivateDevices=
log() { logger -u /run/systemd/journal/dev-log -t "$TAG" -p "daemon.${1}" -- "$2" || true ; }
die() { log err "$1" ; exit "${2:-1}" ; }
cleanup() { local rc=$? ; [[ -n $TMP && -e $TMP ]] && rm -f -- "$TMP"
            log info "fin d'execution rc=${rc}" ; return 0 ; }
trap cleanup EXIT
trap 'die "interrompu par signal" 1' INT TERM

exec 9<"$LOCK"
flock -n 9 || { log warning "une autre instance tourne deja" ; exit 2 ; }

# Prerequis (code 3)
[[ -r $SRC ]] || die "telemetrie illisible : $SRC" 3
[[ -d $WWW && -w $WWW ]] || die "$WWW non inscriptible pour $(id -un)" 3

# Lecture et controle de la derniere mesure (code 1 si invalide)
mesures=$(wc -l < "$SRC")
ligne=$(tail -n 1 -- "$SRC")
re='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:?[0-9]{2}),([0-9]+(\.[0-9]+)?),([0-9]+)$'
[[ $ligne =~ $re ]] || die "derniere ligne de telemetrie invalide : '${ligne:0:80}'" 1
horodatage=${BASH_REMATCH[1]} ; charge=${BASH_REMATCH[2]} ; mem=${BASH_REMATCH[4]}
hote=$(< /proc/sys/kernel/hostname)
genere=$(date --iso-8601=seconds)

# Ecriture atomique : fichier temporaire dans le MEME repertoire, puis rename(2).
# Un lecteur voit soit l'ancien etat.json complet, soit le nouveau, jamais un fichier a moitie ecrit.
TMP=$(mktemp "$WWW/.etat.json.XXXXXX") || die "creation du fichier temporaire impossible" 1
printf '{\n  "genere": "%s",\n  "hote": "%s",\n  "derniere_mesure": "%s",\n  "charge_1min": %s,\n  "mem_dispo_ko": %s,\n  "mesures": %s\n}\n' \
    "$genere" "$hote" "$horodatage" "$charge" "$mem" "$mesures" > "$TMP" || die "ecriture de $TMP impossible" 1
chmod 0640 -- "$TMP"
mv -f -- "$TMP" "$DEST" || die "publication de $DEST impossible" 1
TMP=""
log info "etat.json publie : derniere mesure $horodatage, charge $charge, $mesures mesures"
exit 0
