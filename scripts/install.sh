#!/bin/sh
# Install/switch/revert UPSTREAM klipper3d host for Creality K2 (base F021)
# on STOCK firmware. Run ON the printer as root:
#   sh install.sh            # install + switch to vanilla klippy
#   sh install.sh revert     # back to stock Creality klippy
#   sh install.sh status     # what is running
#
# Host python: the STOCK klippy-env venv (/usr/share/klippy-env) — it already
# ships cffi+greenlet compiled for the printer. Entware provides only
# gcc+make to build c_helper.so. MCUs stay on stock Creality firmware.
#
# Live-tested on hardware 2026-09-02 (see repo history).

set -u

KLIPPER_TAG="${K2_VANILLA_KLIPPER_TAG:-v0.13.0}"
ROOT=/mnt/UDISK
SRC_DIR=$ROOT/klipper-vanilla
CFG_DIR=$ROOT/printer_data/config-vanilla
LOG_DIR=$ROOT/printer_data/logs
LOG_FILE=$LOG_DIR/klippy-vanilla.log
STATE=$ROOT/k2setup/vanilla.state
VAN_INIT=/etc/init.d/klipper-vanilla
HOST_PY=/usr/share/klippy-env/bin/python
HERE=$(cd "$(dirname "$0")" && pwd)

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"
# Entware is only needed to BUILD chelper on-printer; the kit ships a
# prebuilt hard-float c_helper.so, so a bare stock system works without it.
if [ ! -x /opt/bin/opkg ] && [ ! -f "$HERE/../files/c_helper.so" ]; then
    die "Entware not found (/opt/bin/opkg) and no prebuilt files/c_helper.so"
fi
[ -x "$HOST_PY" ] || die "stock klippy-env python missing: $HOST_PY"
"$HOST_PY" -c 'import cffi, greenlet' 2>/dev/null || die "$HOST_PY lacks cffi/greenlet"

model=$(sed -n 's/^# \(F0[0-9]*\).*/\1/p' $ROOT/printer_data/config/printer.cfg 2>/dev/null | head -1)
[ "$model" = "F021" ] || say "WARNING: active config header says '${model:-?}', kit is built for F021 (base). Continuing."

find_stock_init() {
    for n in /etc/init.d/klipper /etc/init.d/klippy; do
        [ -f "$n" ] && { echo "$n"; return; }
    done
    ls /etc/init.d | grep -i klip | head -1 | sed 's|^|/etc/init.d/|'
}

# API socket used by the RUNNING stock klippy (its -a argument).
stock_api_sock() {
    local pid line
    pid=$(ps w | grep 'klippy\.py' | grep -v grep | head -1 | awk '{print $1}')
    [ -n "${pid:-}" ] || { echo "/tmp/klippy_uds"; return; }
    line=$(tr '\0' '\n' < /proc/$pid/cmdline 2>/dev/null | grep -A1 '^-a$' | tail -1)
    [ -n "${line:-}" ] && echo "$line" || echo "/tmp/klippy_uds"
}

status_cmd() {
    if [ -f /etc/init.d/klipper-vanilla ] && /etc/init.d/klipper-vanilla enabled; then
        echo "active: VANILLA klipper ($KLIPPER_TAG), stock service disabled"
    else
        echo "active: stock Creality klipper"
    fi
}

do_deps() {
    if [ ! -x /opt/bin/opkg ]; then
        [ -f "$HERE/../files/c_helper.so" ] || die "no Entware and no prebuilt c_helper.so"
        say "Entware absent — skipping gcc/make (prebuilt c_helper.so will be used)"
    else
        say "Installing Entware gcc/make (chelper build only)"
        opkg install gcc make 2>&1 | tail -1
        if [ ! -x /opt/bin/gcc ] && [ ! -f "$HERE/../files/c_helper.so" ]; then
            die "Entware gcc not available; chelper cannot be built"
        fi
    fi
    say "Host python check: $("$HOST_PY" --version 2>&1)"
}

do_fetch() {
    if [ -f "$SRC_DIR/klippy/klippy.py" ] && [ -f "$SRC_DIR/klippy/chelper/__init__.py" ]; then
        say "Klipper tree already present at $SRC_DIR — skipping download"
        return
    fi
    local tarball="${K2_VANILLA_TARBALL:-$ROOT/k2setup/klipper-$KLIPPER_TAG.tar.gz}"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    if [ -f "$tarball" ]; then
        say "Extracting local tarball $tarball"
        "$HOST_PY" - "$tarball" "$SRC_DIR" <<'PYEOF'
import sys, tarfile, os, shutil
tarball, dest = sys.argv[1], sys.argv[2]
# /tmp is a small ramdisk on this device — extract on UDISK instead
xd = os.path.join(os.path.dirname(dest), "k2setup", "extract")
with tarfile.open(tarball) as tf:
    tf.extractall(xd)
top = os.path.join(xd, os.listdir(xd)[0])
for n in os.listdir(top):
    dst = os.path.join(dest, n)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    elif os.path.exists(dst):
        os.remove(dst)
    shutil.move(os.path.join(top, n), dst)
shutil.rmtree(xd)
print("extracted", tarball, "->", dest)
PYEOF
    else
        say "Downloading Klipper $KLIPPER_TAG (codeload tarball)"
        "$HOST_PY" - "$KLIPPER_TAG" "$SRC_DIR" <<'PYEOF'
import sys, tarfile, tempfile, urllib.request, os, shutil
tag, dest = sys.argv[1], sys.argv[2]
url = f"https://codeload.github.com/Klipper3d/klipper/tar.gz/refs/tags/{tag}"
tmp = tempfile.mktemp(suffix=".tar.gz", dir=os.path.dirname(dest))
xd = os.path.join(os.path.dirname(dest), "k2setup", "extract")
for attempt in range(5):
    try:
        urllib.request.urlretrieve(url, tmp)
        break
    except Exception as e:
        print("download retry", attempt + 1, e)
else:
    raise SystemExit("download failed")
with tarfile.open(tmp) as tf:
    tf.extractall(xd)
top = os.path.join(xd, os.listdir(xd)[0])
for n in os.listdir(top):
    dst = os.path.join(dest, n)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    elif os.path.exists(dst):
        os.remove(dst)
    shutil.move(os.path.join(top, n), dst)
shutil.rmtree(xd); os.remove(tmp)
print("extracted", tag, "->", dest)
PYEOF
    fi
    [ -f "$SRC_DIR/klippy/klippy.py" ] || die "klipper source missing after extract"
}

do_extras() {
    say "Vendoring K2 extras (GPL-3, Jacob10383/kalico) into klippy/extras"
    for f in "$HERE"/../files/*.py "$HERE"/../files/*.json; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in patch_v013.py|remote.py) continue ;; esac
        cp "$f" "$SRC_DIR/klippy/extras/" || die "copy $f failed"
    done
    # Entware kernel headers break chelper build: linux/can.h needs sa_family_t
    # from sys/socket.h (musl). Upstream order works on glibc hosts only.
    sed -i 's|#include <linux/can.h>|#include <sys/socket.h>\n#include <linux/can.h>|' "$SRC_DIR/klippy/chelper/serialqueue.c"
    grep -q "sys/socket.h" "$SRC_DIR/klippy/chelper/serialqueue.c" || die "can.h patch failed"
    # Entware gcc 8.4 LTO produces a .so musl cannot dlopen ("internal error").
    sed -i 's/ -flto -fwhole-program -fno-use-linker-plugin//'         "$SRC_DIR/klippy/chelper/__init__.py"
    grep -q "flto" "$SRC_DIR/klippy/chelper/__init__.py" && die "LTO patch failed" || true
    "$HOST_PY" "$HERE/../files/patch_v013.py" "$SRC_DIR" || die "v0.13 patches failed"
    # Relax multi-MCU trsync timeout (slow dual-A7 host; same fix AD5M mods use
    # for E0011-style "Lost communication with MCU" on upstream hosts).
    sed -i 's/TRSYNC_TIMEOUT = 0.025/TRSYNC_TIMEOUT = 0.05/'         "$SRC_DIR/klippy/mcu.py"
    grep -q "TRSYNC_TIMEOUT = 0.05" "$SRC_DIR/klippy/mcu.py"         || die "TRSYNC patch failed"
    # GD32 needs 60-90s to reboot after the CRC-mismatch reset while stock
    # connect budget is 90s total with a 5s identify wait - extend both.
    sed -i 's/if self.reactor.monotonic() > start_time + 90.:/if self.reactor.monotonic() > start_time + 300.:/'         "$SRC_DIR/klippy/serialhdl.py"
    sed -i 's/completion.wait(self.reactor.monotonic() + 5.)/completion.wait(self.reactor.monotonic() + 15.)/'         "$SRC_DIR/klippy/serialhdl.py"
    grep -q "start_time + 300." "$SRC_DIR/klippy/serialhdl.py"         || die "serialhdl budget patch failed"
    # Prebuilt hard-float c_helper.so (cross-built for this SoC, glibc 2.29).
    # Newest mtime beats sources -> klippy skips its own (unsupported) build.
    if [ -f "$HERE/../files/c_helper.so" ]; then
        cp "$HERE/../files/c_helper.so" "$SRC_DIR/klippy/chelper/c_helper.so" || die "prebuilt .so copy failed"
        say "Prebuilt c_helper.so installed (no on-printer build needed)"
    fi
}

do_config() {
    say "Deploying config to $CFG_DIR (stock config untouched)"
    mkdir -p "$CFG_DIR" "$LOG_DIR"
    cp "$HERE"/../config/*.cfg "$CFG_DIR"/ || die "config copy failed"
    # UDISK NAND quirk: freshly overwritten pages can read back stale/mixed
    # for minutes (klippy once parsed a half-old config -> bogus errors).
    # Verify every deployed file byte-for-byte before restarting klippy.
    local f tries sum_src sum_dst
    for f in "$HERE"/../config/*.cfg; do
        sum_src=$(md5sum < "$f" | cut -d' ' -f1)
        tries=0
        while :; do
            sum_dst=$(md5sum < "$CFG_DIR/$(basename "$f")" | cut -d' ' -f1)
            [ "$sum_src" = "$sum_dst" ] && break
            tries=$((tries+1))
            [ "$tries" -gt 60 ] && die "config verify failed: $(basename "$f")"
            cp "$f" "$CFG_DIR/$(basename "$f")"
            sleep 2
        done
    done
}

make_init() {
    local api_sock; api_sock=$(stock_api_sock)
    say "Using API socket $api_sock (from running stock klippy)"
    cat > "$VAN_INIT" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=01
USE_PROCD=1
start_service() {
    procd_open_instance
    # taskset: pin klippy to the 2nd core — timing stability on the dual-A7
    # (same recipe K2-OpenKlipper validated; arcs resolution must stay 1.0)
    procd_set_param command taskset 0x2 $HOST_PY $SRC_DIR/klippy/klippy.py $CFG_DIR/printer.cfg -a $api_sock -l $LOG_FILE
    procd_set_param env CC=/opt/bin/gcc MALLOC_ARENA_MAX=2 PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
    procd_set_param respawn 360 5 0
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}
EOF
    chmod +x "$VAN_INIT"
}

do_switch() {
    local stock_init; stock_init=$(find_stock_init)
    [ -n "${stock_init:-}" ] || die "stock klipper init script not found"
    say "Disabling stock klipper ($stock_init)"
    "$stock_init" stop 2>/dev/null
    "$stock_init" disable 2>/dev/null
    echo "$stock_init" > "$STATE"
    make_init
    say "mcu_reset: restarting klipper_mcu daemon before klippy (better-init recipe)"
    /etc/init.d/klipper_mcu stop 2>/dev/null
    /etc/init.d/klipper_mcu start 2>/dev/null
    sleep 2
    pidof klipper_mcu >/dev/null || say "WARNING: klipper_mcu daemon not detected"
    "$VAN_INIT" enable
    "$VAN_INIT" start
    install_watchdog
}

install_watchdog() {
    # keeps vanilla alive across cold-boot connect races: restarts the
    # service after repeated connect failures (see scripts/watchdog_loop.sh)
    local loop="$ROOT/k2setup/k2-vanilla/scripts/watchdog_loop.sh"
    [ -f "$loop" ] || loop="$HERE/watchdog_loop.sh"
    [ -f "$loop" ] || return
    cp "$loop" "$ROOT/k2setup/k2-vanilla/scripts/watchdog_loop.sh" 2>/dev/null
    cat > /etc/init.d/k2van-watchdog <<WDEOF
#!/bin/sh /etc/rc.common
START=99
STOP=01
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh $loop
    procd_set_param respawn 360 5 0
    procd_set_param stdout 0
    procd_set_param stderr 0
    procd_close_instance
}
WDEOF
    chmod +x /etc/init.d/k2van-watchdog
    /etc/init.d/k2van-watchdog enable
    /etc/init.d/k2van-watchdog start
    say "Watchdog installed (auto-restart on repeated connect failures)"
}

wait_ready() {
    # NOTE: transient Tracebacks in the log are NORMAL here (first-run CRC
    # dance: the MCU forgets its config CRC, klippy restarts it and retries;
    # the GD32 also needs ~60-90s to come back after 'reset'). Only success
    # or the full timeout decides.
    # v0.13 does NOT log a ready banner - readiness is only visible via the
    # Moonraker API (klippy_state: ready).
    say "Waiting up to 420s for klippy_state=ready"
    i=0
    while [ $i -lt 420 ]; do
        # stock busybox may lack wget — ask the stock python instead
        state=$("$HOST_PY" - <<'PYEOF' 2>/dev/null
import json, urllib.request
try:
    info = json.load(urllib.request.urlopen("http://127.0.0.1:7125/printer/info", timeout=3))
    print(info.get("klippy_state") or info.get("state") or "")
except Exception:
    pass
PYEOF
)
        if [ "$state" = "ready" ]; then
            say "VANILLA KLIPPER IS UP"
            return 0
        fi
        sleep 3; i=$((i+3))
    done
    say "timeout: klippy never reached ready state"
    return 1
}

do_rollback() {
    say "FAILED — rolling back to stock klippy"
    "$VAN_INIT" stop 2>/dev/null; "$VAN_INIT" disable 2>/dev/null
    local stock_init; stock_init=$(cat "$STATE" 2>/dev/null)
    [ -n "${stock_init:-}" ] && { "$stock_init" enable; "$stock_init" start; }
    echo "----- klippy log tail -----"
    tail -40 "$LOG_FILE" 2>/dev/null
    exit 1
}

do_revert() {
    say "Reverting to stock Creality klippy"
    "$VAN_INIT" stop 2>/dev/null; "$VAN_INIT" disable 2>/dev/null
    local stock_init; stock_init=$(cat "$STATE" 2>/dev/null)
    [ -n "${stock_init:-}" ] || stock_init=$(find_stock_init)
    [ -n "${stock_init:-}" ] || die "stock init not found"
    "$stock_init" enable; "$stock_init" start
    say "Stock klippy restored. Vanilla files kept in $SRC_DIR (remove manually if unwanted)."
}

case "${1:-install}" in
    status)  status_cmd ;;
    revert)  do_revert ;;
    deps)    do_deps ;;
    install)
        do_deps
        do_fetch
        do_extras
        do_config
        : > "$LOG_FILE"
        do_switch
        if wait_ready; then
            say "Done. Fluidd/Mainsail reconnect automatically (same API socket)."
            say "Screen (Creality UI) may partially misbehave — stop display-server if so."
            say "Revert anytime: sh $0 revert"
        else
            do_rollback
        fi
        ;;
    *) die "usage: install.sh [install|revert|status|deps]" ;;
esac
