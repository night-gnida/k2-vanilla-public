#!/bin/sh
# k2-vanilla watchdog loop: keeps vanilla klippy alive on the K2.
# Checks moonraker /printer/info every 60s. Consecutive failures
# (connection refused / klippy_state=error with "Unable to connect")
# trigger a klipper-vanilla service restart. After MAX_RESTARTS attempts
# it stops interfering and drops a flag file for manual attention.

LOOP=/mnt/UDISK/k2setup/k2-vanilla/scripts/watchdog_loop.sh
FLAG=/mnt/UDISK/k2setup/watchdog.gaveup
STATE=/mnt/UDISK/k2setup/watchdog.state
MAX_RESTARTS=5
FAILS_NEEDED=3

mkdir -p "$(dirname "$FLAG")"

fails=0
restarts=$(cat "$STATE" 2>/dev/null | grep -oE 'restarts=[0-9]+' | cut -d= -f2)
[ -n "$restarts" ] || restarts=0

log() { echo "$(date '+%b %d %H:%M:%S') watchdog: $*" >> /mnt/UDISK/printer_data/logs/klippy-vanilla.log; }

while :; do
    sleep 60
    [ -f /etc/init.d/klipper-vanilla ] || continue
    /etc/init.d/klipper-vanilla enabled || continue

    # stock OpenWrt busybox may lack the wget applet — use stock python3
    body=$(/usr/bin/python3 -c '
import json, urllib.request
try:
    info = json.load(urllib.request.urlopen("http://127.0.0.1:7125/printer/info", timeout=3))
    print(json.dumps(info))
except Exception:
    pass' 2>/dev/null)
    case "$body" in
        *'"state": "ready"'*|*'"state":"ready"'*|*'"klippy_state": "ready"'*|*'"klippy_state":"ready"'*)
            fails=0
            continue
            ;;
        "")
            # moonraker unreachable or klippy socket down
            fails=$((fails + 1))
            ;;
        *)
            # klippy answered: error state counts only when it mentions
            # the connect failure class we know how to fix
            case "$body" in
                *"Unable to connect"*|*"Printer is not ready"*)
                    fails=$((fails + 1))
                    ;;
                *)
                    fails=0
                    ;;
            esac
            ;;
    esac

    if [ "$fails" -ge "$FAILS_NEEDED" ]; then
        if [ "$restarts" -ge "$MAX_RESTARTS" ]; then
            log "gave up after $restarts restarts - manual attention needed"
            touch "$FLAG"
            # keep watching silently; do not spam restarts
            continue
        fi
        restarts=$((restarts + 1))
        echo "restarts=$restarts" > "$STATE"
        log "connect failures x$fails - mcu_reset + restarting klipper-vanilla (attempt $restarts/$MAX_RESTARTS)"
        /etc/init.d/klipper_mcu stop 2>/dev/null
        /etc/init.d/klipper_mcu start 2>/dev/null
        sleep 2
        /etc/init.d/klipper-vanilla restart 2>/dev/null
        fails=0
    fi
done
