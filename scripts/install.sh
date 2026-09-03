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
[ -x /opt/bin/opkg ] || die "Entware not found (/opt/bin/opkg). Install it first (helper menu: entware)."
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
    say "Installing Entware gcc/make (chelper build only)"
    opkg install gcc make 2>&1 | tail -1
    [ -x /opt/bin/gcc ] || die "Entware gcc not available; chelper cannot be built"
    say "Host python check: $("$HOST_PY" --version 2>&1)"
}

do_fetch() {
    if [ -f "$SRC_DIR/klippy/klippy.py" ] && [ -f "$SRC_DIR/klippy/chelper/__init__.py" ]; then
        say "Klipper tree already present at $SRC_DIR — skipping download"
        return
    fi
    say "Downloading Klipper $KLIPPER_TAG (codeload tarball)"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    python3 - "$KLIPPER_TAG" "$SRC_DIR" <<'PYEOF'
import sys, tarfile, tempfile, urllib.request, os, shutil
tag, dest = sys.argv[1], sys.argv[2]
url = f"https://codeload.github.com/Klipper3d/klipper/tar.gz/refs/tags/{tag}"
tmp = tempfile.mktemp(suffix=".tar.gz")
for attempt in range(5):
    try:
        urllib.request.urlretrieve(url, tmp)
        break
    except Exception as e:
        print("download retry", attempt + 1, e)
else:
    raise SystemExit("download failed")
with tarfile.open(tmp) as tf:
    tf.extractall("/tmp/klipper-vanilla-x")
top = os.path.join("/tmp/klipper-vanilla-x", os.listdir("/tmp/klipper-vanilla-x")[0])
for n in os.listdir(top):
    dst = os.path.join(dest, n)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    elif os.path.exists(dst):
        os.remove(dst)
    shutil.move(os.path.join(top, n), dst)
shutil.rmtree("/tmp/klipper-vanilla-x"); os.remove(tmp)
print("extracted", tag, "->", dest)
PYEOF
    [ -f "$SRC_DIR/klippy/klippy.py" ] || die "klipper source missing after extract"
}

do_extras() {
    say "Vendoring K2 extras (GPL-3, Jacob10383/kalico) into klippy/extras"
    for f in "$HERE"/../files/*.py "$HERE"/../files/*.json; do
        [ -e "$f" ] || continue
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
    procd_set_param command $HOST_PY $SRC_DIR/klippy/klippy.py $CFG_DIR/printer.cfg -a $api_sock -l $LOG_FILE
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
    "$VAN_INIT" enable
    "$VAN_INIT" start
}

wait_ready() {
    # NOTE: transient Tracebacks in the log are NORMAL here (first-run CRC
    # dance: the MCU forgets its config CRC, klippy restarts it and retries;
    # the GD32 also needs ~60-90s to come back after 'reset'). Only success
    # or the full timeout decides.
    say "Waiting up to 420s for 'Printer is ready'"
    i=0
    while [ $i -lt 420 ]; do
        if grep -q "Printer is ready" "$LOG_FILE" 2>/dev/null; then
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
