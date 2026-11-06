# RUNBOOK — Portail de suivi des tournées (`helios-suivi`)

Fiche d'astreinte. Serveur : `srv-core` (SSH sur le port **2242**, réseau d'administration). Le portail est sur `http://10.42.0.10:8080/` (réseau métier).
Lea (groupe `suivi`) peut lancer les commandes marquées 🟢 avec `sudo`. Pour les autres, il faut un administrateur (`sudo -i`).
Avant de commencer et après avoir réparé, une commande résume tout : `sudo /usr/local/sbin/helios-suivi-audit.sh` (attendu : `Bilan : 9/9`).

## 1. Le portail ne répond plus
- **Symptôme :** l'alerte Zabbix `helios.suivi.http` est différente de 200 (`000` si le portail ne répond pas du tout).
- **Diagnostic :** 🟢 `sudo systemctl status --no-pager helios-suivi.service` puis 🟢 `sudo journalctl -u helios-suivi.service -n 100 --no-pager`
- **Réparation :** 🟢 `sudo systemctl restart helios-suivi.service`. S'il ne démarre toujours pas, un admin lance `systemctl reset-failed helios-suivi.service` puis `systemctl start helios-suivi.service`.
- **Vérification :** `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/etat.json` → `200`

## 2. `etat.json` est figé
- **Symptôme :** l'alerte Zabbix `helios.suivi.age` dépasse 300 secondes.
- **Diagnostic :** `systemctl list-timers helios-suivi-publish.timer` · 🟢 `sudo journalctl -u helios-suivi-publish.service -n 100 --no-pager`. Si on y voit `rc=1`, la ligne de télémétrie est invalide ; si on y voit `rc=3`, la télémétrie est illisible. · `systemctl is-active helios-collect.service`
- **Réparation :** (admin) `systemctl restart helios-collect.service` si la collecte est arrêtée, et `systemctl start helios-suivi-publish.timer` si le timer est arrêté. Ensuite, 🟢 `sudo systemctl start helios-suivi-publish.service`.
- **Vérification :** `zabbix_get -s 127.0.0.1 -k helios.suivi.age` → un nombre inférieur à 120

## 3. Injoignable depuis le réseau métier alors que le service tourne
- **Symptôme :** sur srv-core, `curl` répond 200, mais depuis le réseau métier (srv-edge) on obtient `Connection timed out` ou `No route to host`.
- **Diagnostic :** (admin) `firewall-cmd --zone=internal --query-port=8080/tcp` · `firewall-cmd --get-active-zones` (`bond0` doit être dans `internal`) · `ip -br a show bond0` · `firewall-cmd --ipset=helios-blacklist --get-entries` (le client est peut-être bloqué)
- **Réparation :** `firewall-cmd --reload` (cela recharge la configuration permanente, où 8080 est ouvert dans `internal`) · si l'adresse du client est dans l'ipset : `firewall-cmd --ipset=helios-blacklist --remove-entry=<IP>`, puis la même commande avec `--permanent`. **Jamais** ouvrir 8080 dans une autre zone.
- **Vérification :** depuis srv-edge, `curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.10:8080/etat.json` → `200`

## 4. Restaurer le portail après une suppression ou une corruption
- **Symptôme :** la page d'accueil affiche « Directory listing for / » ou un contenu faux, ou l'audit indique `[KO] E2`.
- **Diagnostic :** (admin) `L=$(ls -1 /srv/helios/archives/suivi/suivi-*.tar.gz | sort | tail -1)` · `cd /srv/helios/archives/suivi && sha256sum -c $(basename $L).sha256` → `OK`
- **Réparation :** pour un seul fichier : `tar --acls --xattrs --selinux -xzpf $L -C / srv/helios/suivi/www/index.html`. Pour tout le portail : la même commande avec `srv/helios/suivi`.
- **Vérification :** `getfacl -p /srv/helios/suivi/www/index.html` (`lea:suivi`, `user:helios-suivi:r`) · `curl -s http://127.0.0.1:8080/ | grep title` → « Suivi des tournees » · audit `9/9`
