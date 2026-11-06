#!/usr/bin/bash
# e.sh — PROJET : tests depuis srv-edge (en david). E6 : 8080 joignable sur le reseau metier seulement.
OUT=~/projet-edge.txt ; : > "$OUT"
t() { printf '$ %s\n' "$*" | tee -a "$OUT"; bash -c "$*" 2>&1 | tee -a "$OUT"; }
clear
printf '=== PROJET E6/E7 — tests depuis srv-edge — %s ===\n' "$(date '+%F %T')" | tee -a "$OUT"
t "ip -br -4 addr | grep -v '^lo'"
t "curl -s -o /dev/null -m 5 -w 'reseau metier : GET http://10.42.0.10:8080/etat.json -> %{http_code}\n' http://10.42.0.10:8080/etat.json"
t "curl -s -m 5 http://10.42.0.10:8080/etat.json"
t "curl -s -o /dev/null -m 5 -w 'reseau admin  : GET http://192.168.56.10:8080/etat.json -> %{http_code}\n' http://192.168.56.10:8080/etat.json ; echo \"rc curl=\$?  (attendu != 0)\""
if command -v nc >/dev/null; then
    t "nc -zv -w2 192.168.56.10 8080 ; echo \"rc nc=\$?  (attendu != 0)\""
else
    t "timeout 3 bash -c 'exec 3<>/dev/tcp/192.168.56.10/8080' ; echo \"rc=\$?  (nc absent de srv-edge : meme test avec /dev/tcp, attendu != 0)\""
fi
t "ssh -p 2242 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 lea@192.168.56.10 true ; echo \"rc=\$?  (E7 : lea refusee, attendu 255)\""
echo ; echo "Termine : retourne sur srv-core et appuie sur Entree. (sortie dans $OUT)"
