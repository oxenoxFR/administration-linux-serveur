#!/usr/bin/bash
# lib.sh — fonctions communes aux scripts d'installation du projet (a sourcer).
P_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_CFG="$P_DIR/configs"                 # fichiers a installer
OUT=/root/PROJET                         # rendu : configs/ et preuves/
CFG="$OUT/configs" ; PRV="$OUT/preuves"
mkdir -p "$CFG" "$PRV"
export LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

V=$'\033[1;32m'; R=$'\033[1;31m'; J=$'\033[1;33m'; C=$'\033[1;36m'; N=$'\033[0m'
ok()   { printf '%s[OK]%s %s\n' "$V" "$N" "$*" | tee -a "$PRV/$F"; }
ko()   { printf '%s[KO]%s %s\n' "$R" "$N" "$*" | tee -a "$PRV/$F"; }
info() { printf '%s[i]%s %s\n'  "$J" "$N" "$*"; }

# ecran <fichier> <titre> : nouvel ecran (une capture d'ecran par ecran) + nouveau fichier de preuve
ecran() {
    F="$1"; shift
    clear
    printf '%s=== PROJET %s — srv-core — %s ===%s\n' "$C" "$*" "$(date '+%F %T')" "$N"
    printf '=== %s — %s ===\n' "$*" "$(date '+%F %T')" >> "$PRV/$F"
}
# run '<commande>' : affiche, execute et archive la commande et sa sortie dans $PRV/$F
run() {
    printf '$ %s\n' "$*" | tee -a "$PRV/$F"
    bash -c "$*" 2>&1 | tee -a "$PRV/$F"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}
# runc '<commande>' : comme run, mais n'affiche que 118 colonnes a l'ecran (le fichier garde tout)
runc() {
    printf '$ %s\n' "$*" | tee -a "$PRV/$F" | cut -c1-122
    bash -c "$*" 2>&1 | tee -a "$PRV/$F" | cut -c1-122
    return "${PIPESTATUS[0]}"
}
pause() {
    printf '\n%s>>> %s%s ' "$J" "${*:-capture d ecran, puis Entree}" "$N"
    read -r _ </dev/tty
}
exiger_root() { [[ $EUID -eq 0 ]] || { echo "Lance-moi en root (sudo -i)"; exit 1; }; }
# depuis <t0> : secondes ecoulees depuis t0 (date +%s.%N) ; calc <expr> : calcul a 1 decimale (bc absent du socle)
depuis() { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'; }
calc()   { awk "BEGIN{printf \"%.1f\", $*}"; }
export -f depuis calc
