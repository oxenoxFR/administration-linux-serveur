#!/usr/bin/bash
# p4.sh — justification (b) : ce qui se passe sans l'entree ACL user:zabbix:--x sur www, puis avec r-x.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
exiger_root
W=/srv/helios/suivi/www
PRINTK=$(awk '{print $1}' /proc/sys/kernel/printk); dmesg -n 1
trap 'setfacl -m u:zabbix:--x '"$W"' ; dmesg -n "$PRINTK"' EXIT     # l'entree --x est TOUJOURS remise
ecran 17-E2-acl-zabbix.txt "Justification (b) — zabbix : sans entree, avec r-x, avec --x"
run "getfacl -p $W | grep zabbix"
run "setfacl -x u:zabbix $W ; echo '--- 1. entree user:zabbix RETIREE ---' ; runuser -u zabbix -- stat -c '%n %Y' $W/etat.json ; zabbix_get -s 127.0.0.1 -k helios.suivi.age"
run "setfacl -m u:zabbix:r-x $W ; echo '--- 2. user:zabbix:r-x ---' ; runuser -u zabbix -- ls $W ; zabbix_get -s 127.0.0.1 -k helios.suivi.age"
run "setfacl -m u:zabbix:--x $W ; echo '--- 3. user:zabbix:--x (configuration retenue) ---' ; runuser -u zabbix -- ls $W ; zabbix_get -s 127.0.0.1 -k helios.suivi.age"
run "getfacl -p $W | grep zabbix ; /usr/local/sbin/helios-suivi-audit.sh | tail -1"
run "ls -ld /var/lib/helios ; ls -l /var/lib/helios/telemetry.csv ; getfacl -p --omit-header /var/lib/helios/telemetry.csv | grep -E 'user:|group::|other'"
cp "$PRV/17-E2-acl-zabbix.txt" /tmp/res/preuves/ && chown david:david /tmp/res/preuves/17-E2-acl-zabbix.txt
pause "capture d ecran, puis Entree pour terminer"
