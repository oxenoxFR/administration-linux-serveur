#!/usr/bin/bash
# TP3 — tests depuis srv-edge (poste distant : administrateur ET attaquant).
# A lancer EN TANT QUE david (pas root) : la cle SSH doit etre celle de david.
# Usage : bash tp3-edge.sh avant | parefeu | ssh | attaque | bloque | rattrapage
set -uo pipefail
CORE=192.168.56.10
U="${ADMIN_USER:-david}"
CAP="$(cd "$(dirname "$0")/.." && pwd)/captures"; mkdir -p "$CAP"
C=$'\033[1;36m'; V=$'\033[1;32m'; R=$'\033[1;31m'; J=$'\033[1;33m'; N=$'\033[0m'
titre() { printf '\n%s==== %s ====%s\n' "$C" "$*" "$N"; }
ok()    { printf '%s[OK]%s %s\n' "$V" "$N" "$*"; }
ko()    { printf '%s[KO]%s %s\n' "$R" "$N" "$*"; }
info()  { printf '%s[i]%s %s\n'  "$J" "$N" "$*"; }
run()   { local out="$CAP/$1"; shift; printf '\n$ %s\n' "$*" | tee -a "$out"; bash -c "$*" 2>&1 | tee -a "$out"; return "${PIPESTATUS[0]}"; }
SSHO="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

[[ $(hostname -s) == srv-edge ]] || { ko "A lancer sur srv-edge"; exit 1; }
[[ $EUID -ne 0 ]] || { ko "Lance-le en tant que $U, pas en root (sudo -i)"; exit 1; }

case "${1:-}" in
avant)
    F=edge-avant.txt; : > "$CAP/$F"
    titre "Preparation de srv-edge"
    rpm -q nmap &>/dev/null || sudo dnf -y -q install nmap nmap-ncat
    titre "nmap AVANT securisation"
    run $F "nmap -Pn -p 22,80,2242,10051 $CORE"
    titre "Cle SSH de $U (srv-edge -> srv-core)"
    [[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -a 100 -C "$U@srv-edge" -f ~/.ssh/id_ed25519 -N ''
    info "ssh-copy-id va demander le mot de passe de $U sur srv-core : tape-le toi-meme."
    ssh-copy-id $SSHO -i ~/.ssh/id_ed25519.pub "$U@$CORE"
    run $F "ssh $SSHO -o BatchMode=yes $U@$CORE 'hostname ; id'" && ok "Connexion par cle OK" || ko "La connexion par cle ne marche pas : ne lance PAS tp3-core-a.sh"
    ;;
parefeu)
    F=edge-parefeu.txt; : > "$CAP/$F"
    titre "1.5 — Tests du pare-feu depuis srv-edge"
    run $F "nmap -Pn -p 22,80,10051 $CORE"
    run $F "nc -zv -w 3 $CORE 22"
    run $F "nc -zv -w 2 $CORE 10051 ; echo \"rc attendu != 0 : \$?\""
    titre "Rafale de 12 connexions (limite 6/min)"
    run $F "for i in \$(seq 1 12); do nc -zv -w1 $CORE 22 2>&1 | tail -1 ; done"
    ok "Termine — retourne sur srv-core et appuie sur Entree"
    ;;
ssh)
    F=edge-7-tests.txt; : > "$CAP/$F"
    titre "2.5 — Les sept tests SSH"
    res() { if [[ $2 == "$3" ]]; then ok "$1 : $4"; echo "=> $1 : OK ($4)" >> "$CAP/$F"; else ko "$1 : $4 (rc=$2)"; echo "=> $1 : INATTENDU rc=$2" >> "$CAP/$F"; fi; }
    run $F "nc -zv -w2 $CORE 22"; rc=$?; res "1. ancien port 22" $((rc!=0)) 1 "refuse"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes $U@$CORE 'hostname; id -nG'"; res "2. $U par cle sur 2242" $? 0 "accepte"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes root@$CORE id"; rc=$?; res "3. root" $((rc!=0)) 1 "refuse"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password $U@$CORE true"; rc=$?; res "4. mot de passe" $((rc!=0)) 1 "refuse"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes nadia@$CORE true"; rc=$?; res "5. nadia hors ssh-admins" $((rc!=0)) 1 "refuse"
    printf '\n$ ssh -p 2242 -N -L 9999:localhost:10051 %s@%s & ; nc -zv -w2 127.0.0.1 9999\n' "$U" "$CORE" | tee -a "$CAP/$F"
    ssh -p 2242 $SSHO -o BatchMode=yes -o ExitOnForwardFailure=no -N -L 9999:localhost:10051 "$U@$CORE" >>"$CAP/$F" 2>&1 & TPID=$!
    sleep 3; nc -zv -w2 127.0.0.1 9999 2>&1 | tee -a "$CAP/$F"; sleep 2; kill $TPID 2>/dev/null; wait $TPID 2>/dev/null; tail -2 "$CAP/$F"
    grep -qi 'administratively prohibited\|open failed\|refused' "$CAP/$F" && res "6. tunnel vers 10051" 1 1 "refuse a l'usage" || info "6. tunnel : verifie la trace cote srv-core"
    info "Pause de 15 s (limite de debit du pare-feu)"; sleep 15
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes -o KexAlgorithms=diffie-hellman-group14-sha1 $U@$CORE true"; rc=$?; res "7. KEX SHA-1" $((rc!=0)) 1 "refuse"
    titre "nmap APRES securisation"
    run edge-apres.txt "nmap -Pn -p 22,80,2242,10051 $CORE"
    ok "Termine — retourne sur srv-core et appuie sur Entree"
    ;;
attaque)
    F=edge-attaque.txt; : > "$CAP/$F"
    titre "3.4 — Simulation d'attaque : 10 essais avec un utilisateur inexistant"
    for i in $(seq 1 10); do
        ssh -p 2242 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 pirate@$CORE true 2>&1 | tail -1 | tee -a "$CAP/$F"
    done
    ok "Termine — retourne sur srv-core et appuie sur Entree"
    ;;
bloque)
    F=edge-bloque.txt; : > "$CAP/$F"
    titre "srv-edge est-elle bloquee ?"
    run $F "nc -zv -w3 $CORE 2242 ; echo \"rc attendu != 0 : \$?\""
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes $U@$CORE hostname ; echo \"rc attendu != 0 : \$?\""
    ok "Termine — retourne sur srv-core et appuie sur Entree"
    ;;
rattrapage)
    # nc et nmap absents sur srv-edge : on teste les ports avec /dev/tcp de bash.
    tcp() { local out rc; out=$(LC_ALL=C timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1); rc=$?
        if   ((rc==0));   then echo "$1:$2 -> ouvert (connexion acceptee)"; return 0
        elif ((rc==124)); then echo "$1:$2 -> filtre (aucune reponse, paquet jete)"; return 3
        elif [[ $out == *refused* ]]; then echo "$1:$2 -> ferme (connexion refusee)"; return 1
        else echo "$1:$2 -> rejete par le pare-feu (${out##*: })"; return 2; fi; }
    export -f tcp
    F=edge-7-tests.txt; : > "$CAP/$F"
    titre "2.5 — Les sept tests SSH ($(date '+%F %T'))"
    res() { if [[ $2 == "$3" ]]; then ok "$1 : $4"; echo "=> $1 : OK ($4)" >> "$CAP/$F"; else ko "$1 : $4 (rc=$2)"; echo "=> $1 : INATTENDU rc=$2" >> "$CAP/$F"; fi; }
    run $F "tcp $CORE 22"; rc=$?; res "1. ancien port 22" $((rc!=0)) 1 "refuse"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes $U@$CORE 'hostname; id -nG'"; res "2. $U par cle sur 2242" $? 0 "accepte"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes root@$CORE id"; rc=$?; res "3. root" $((rc!=0)) 1 "refuse"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password $U@$CORE true"; rc=$?; res "4. mot de passe" $((rc!=0)) 1 "refuse"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes nadia@$CORE true"; rc=$?; res "5. nadia hors ssh-admins" $((rc!=0)) 1 "refuse"
    printf '\n$ ssh -p 2242 -N -L 9999:localhost:10051 %s@%s &  puis  tcp 127.0.0.1 9999\n' "$U" "$CORE" | tee -a "$CAP/$F"
    ssh -p 2242 $SSHO -o BatchMode=yes -o ExitOnForwardFailure=no -N -L 9999:localhost:10051 "$U@$CORE" >>"$CAP/$F" 2>&1 & TPID=$!
    sleep 3; tcp 127.0.0.1 9999 2>&1 | tee -a "$CAP/$F"; sleep 2; kill $TPID 2>/dev/null; wait $TPID 2>/dev/null; tail -2 "$CAP/$F"
    grep -qi 'administratively prohibited\|open failed\|refused' "$CAP/$F" && res "6. tunnel vers 10051" 1 1 "refuse a l'usage" || info "6. tunnel : voir la trace"
    info "Pause de 15 s (limite de debit du pare-feu)"; sleep 15
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes -o KexAlgorithms=diffie-hellman-group14-sha1 $U@$CORE true"; rc=$?; res "7. KEX SHA-1" $((rc!=0)) 1 "refuse"

    info "Pause de 65 s pour vider la limite de debit"; sleep 65
    F=edge-apres.txt; : > "$CAP/$F"
    titre "Ports de srv-core vus depuis srv-edge APRES securisation"
    for p in 22 80 2242 10051; do run $F "tcp $CORE $p"; done
    F=edge-preuves-core.txt; : > "$CAP/$F"
    titre "Preuves cote srv-core (journal lu par $U, membre de wheel)"
    run $F "ssh -p 2242 $SSHO -o BatchMode=yes $U@$CORE \"journalctl -t helios-watch-auth --since today --no-pager | grep -v 'une autre instance' | tail -12; echo; journalctl -u sshd --since today -g 'pirate' -o short-iso --no-pager | tail -12; echo; journalctl -k --since today -g 'SSH-NEW' -o short-iso --no-pager | tail -4\""

    info "Pause de 65 s avant la rafale"; sleep 65
    F=edge-rafale.txt; : > "$CAP/$F"
    titre "1.5 — Rafale de 12 connexions sur 2242 (limite 6/min)"
    for i in $(seq 1 12); do printf '%2d : ' "$i" | tee -a "$CAP/$F"; tcp $CORE 2242 | tee -a "$CAP/$F"; done
    ok "Rattrapage termine : captures dans $CAP"
    ;;
*) echo "Usage : bash $0 avant | parefeu | ssh | attaque | bloque | rattrapage"; exit 1 ;;
esac
