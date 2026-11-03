#!/usr/bin/bash
# remplir-rapport.sh — injecte dans RAPPORT.md les mesures relevees par les scripts
# (captures/valeurs.env). Relancable : repart toujours du modele d'origine.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

RAP="$TP_DIR/RAPPORT.md"
MODELE="$TP_DIR/.RAPPORT.modele.md"
[[ -f $MODELE ]] || cp "$RAP" "$MODELE"
[[ -f $VALEURS ]] || { ko "Aucune mesure trouvee ($VALEURS) : lance d'abord les scripts de mission."; exit 1; }

# shellcheck disable=SC1090
source "$VALEURS"

CLES=(BOOT_AVANT BOOT_APRES BLAME_AVANT BLAME_APRES SCORE_AVANT SCORE_APRES KILL9 MEMORYMAX
      INTERVALLE TARGET_STOP PING_PERTES ACTIF_PENDANT PERSISTANCE RC0 RC2 RC3 PERSISTENT
      TIMER_NEXT CRON_JOURNAL BONUS)

contenu="$(<"$MODELE")"
manquants=()
for k in "${CLES[@]}"; do
    v="${!k:-}"
    [[ -n $v ]] || { v="⟨non mesuré⟩"; manquants+=("$k"); }
    contenu="${contenu//"{{$k}}"/"$v"}"
done
printf '%s\n' "$contenu" > "$RAP"

ok "RAPPORT.md rempli avec les mesures de captures/valeurs.env"
(( ${#manquants[@]} )) && info "Valeurs manquantes (relance la mission concernee) : ${manquants[*]}"
exit 0
