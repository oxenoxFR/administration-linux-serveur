#!/usr/bin/bash
# lib.sh — fonctions communes aux scripts du TP1 (a sourcer, pas a executer).

TP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$TP_DIR/configs"
CAP="$TP_DIR/captures"
VALEURS="$CAP/valeurs.env"
mkdir -p "$CAP"

B=$'\033[1m'; C=$'\033[1;36m'; V=$'\033[1;32m'; R=$'\033[1;31m'; J=$'\033[1;33m'; N=$'\033[0m'

titre() { printf '\n%s==== %s ====%s\n' "$C" "$*" "$N"; }
info()  { printf '%s[i]%s %s\n'  "$J" "$N" "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$V" "$N" "$*"; }
ko()    { printf '%s[KO]%s %s\n' "$R" "$N" "$*"; }

# run <fichier_capture> '<commande>' : affiche, execute et archive la commande + sa sortie.
# Renvoie le code retour de la commande.
run() {
    local out="$CAP/$1"; shift
    printf '\n$ %s\n' "$*" | tee -a "$out"
    bash -c "$*" 2>&1 | tee -a "$out"
    return "${PIPESTATUS[0]}"
}

# marque <fichier_capture> '<texte>' : ajoute un intertitre dans une capture
marque() { printf '\n### %s — %s\n' "$2" "$(date '+%F %T')" | tee -a "$CAP/$1"; }

pause() {
    printf '\n%s>>> %s%s\n' "$B" "$*" "$N"
    read -rp '    Appuie sur Entree pour continuer... ' _ </dev/tty
}

confirmer() { local r; read -rp "$* [o/N] " r </dev/tty; [[ $r == [oOyY]* ]]; }

exiger_root() { [[ $EUID -eq 0 ]] || { ko "Lance ce script en root : sudo -i"; exit 1; }; }

exiger_hote() {
    local h; h="$(hostname -s)"
    [[ $h == "$1" ]] && return 0
    ko "Ce script est prevu pour $1, mais cette machine s'appelle « $h »."
    confirmer "Continuer quand meme ?" || exit 1
}

# valeur CLE texte... : memorise une mesure pour remplir-rapport.sh
valeur() {
    local k="$1"; shift
    touch "$VALEURS"
    sed -i "/^${k}=/d" "$VALEURS"
    printf '%s=%q\n' "$k" "$*" >> "$VALEURS"
}

# nm_supprimer <nom> : supprime une connexion NetworkManager si elle existe (script relancable)
nm_supprimer() {
    if nmcli -t -f NAME con show | grep -qxF "$1"; then
        nmcli con delete "$1" >/dev/null && info "Ancienne connexion « $1 » supprimee"
    fi
    return 0
}

# nm_neutraliser <iface> <profil_a_garder>... : coupe l'autoconnect des AUTRES profils
# lies a cette interface, sinon NetworkManager peut les reactiver au reboot a la place des notres.
nm_neutraliser() {
    local ifn="$1"; shift
    local uuid nom dev
    while IFS=: read -r uuid nom; do
        dev="$(nmcli -g connection.interface-name con show "$uuid" 2>/dev/null)"
        [[ $dev == "$ifn" ]] || continue
        printf '%s\n' "$@" | grep -qxF "$nom" && continue
        nmcli con mod "$uuid" connection.autoconnect no \
            && info "Profil « $nom » sur $ifn : autoconnect desactive (il entrerait en conflit)"
        nmcli con down "$uuid" &>/dev/null || true
    done < <(nmcli -t -f UUID,NAME con show)
}
