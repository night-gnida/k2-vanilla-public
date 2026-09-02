#!/bin/sh
# Install/switch/revert UPSTREAM klipper3d host for Creality K2 (base F021)
# on STOCK firmware. Run ON the printer as root:
#   sh install.sh            # install + switch to vanilla klippy
#   sh install.sh revert     # back to stock Creality klippy
#   sh install.sh status     # what is running
#
# Requirements: Entware installed (our helper menu 'entware' step) providing
# gcc/make/python3/pip; stock klipper service present; internet on printer
# (codeload.github.com). MCUs stay on stock Creality firmware.
#
# UNTESTED ON HARDWARE — first run is expected to need on-device fixes.

set -u

KLIPPER_TAG="${K2_VANILLA_KLIPPER_TAG:-v0.13.0}"
ROOT=/mnt/UDISK
SRC_DIR=$ROOT/klipper-vanilla
DEPS_DIR=$ROOT/klipper-vanilla-deps
CFG_DIR=$ROOT/printer_data/config-vanilla
LOG_DIR=$ROOT/printer_data/logs
LOG_FILE=$LOG_DIR/klippy-vanilla.log
STATE=$ROOT/k2setup/vanilla.state
VAN_INIT=/etc/init.d/klipper-vanilla
HERE=$(cd "$(dirname "$0")" && pwd)

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root"
[ -x /opt/bin/opkg ] || die "Entware not found (/opt/bin/opkg). Install it first (helper menu: entware)."

PY=/opt/bin/python3
[ -x "$PY" ] || die "Entware python3 missing: opkg install python3"

model=$(sed -n 's/^# \(F0[0-9]*\).*/\1/p' $ROOT/printer_data/config/printer.cfg 2>/dev/null | head -1)
[ "$model" = "F021" ] || say "WARNING: active config header says '${model:-?}', kit is built for F021 (base). Continuing."

find_stock_init() {
    for n in /etc/init.d/klipper /etc/init.d/klippy; do
        [ -f "$n" ] && { echo "$n"; return; }
    done
    ls /etc/init.d | grep -i klip | head -1 | sed 's|^|/etc/init.d/|'
}

status_cmd() {
    if [ -f /etc/init.d/klipper-vanilla ] && /etc/init.d/klipper-vanilla enabled; then
        echo "active: VANILLA klipper ($KLIPPER_TAG), stock service disabled"
    else
        echo "active: stock Creality klipper"
    fi
}

do_deps() {
    say "Installing Entware packages (gcc, make, python3, pip)"
    opkg install gcc make python3 python3-pip python3-dev libstdc++ 2>/dev/null || true
    [ -x /opt/bin/gcc ] || die "Entware gcc not available; chelper cannot be built"
    say "Installing greenlet into $DEPS_DIR"
    mkdir -p "$DEPS_DIR"
    /opt/bin/python3 -m pip install --target "$DEPS_DIR" greenlet || die "pip greenlet failed"
}

do_fetch() {
    say "Downloading Klipper $KLIPPER_TAG (codeload tarball)"
    mkdir -p "$SRC_DIR"
    $PY - "$KLIPPER_TAG" "$SRC_DIR" <<'PYEOF'
import sys, tarfile, tempfile, urllib.request, os, shutil
tag, dest = sys.argv[1], sys.argv[2]
url = f"https://codeload.github.com/Klipper3d/klipper/tar.gz/refs/tags/{tag}"
tmp = tempfile.mktemp(suffix=".tar.gz")
urllib.request.urlretrieve(url, tmp)
with tarfile.open(tmp) as tf:
    tf.extractall("/tmp/klipper-vanilla-x")
top = os.path.join("/tmp/klipper-vanilla-x", os.listdir("/tmp/klipper-vanilla-x")[0])
for n in os.listdir(top):
    shutil.move(os.path.join(top, n), os.path.join(dest, n))
shutil.rmtree("/tmp/klipper-vanilla-x"); os.remove(tmp)
print("extracted", tag, "->", dest)
PYEOF
    [ -f "$SRC_DIR/klippy/klippy.py" ] || die "klipper source missing after extract"
}

do_extras() {
    say "Vendoring K2 extras (GPL-3, Jacob10383/kalico) into klippy/extras"
    for f in "$HERE"/../files/*.py; do
        cp "$f" "$SRC_DIR/klippy/extras/" || die "copy $f failed"
    done
}

do_config() {
    say "Deploying config to $CFG_DIR (stock config untouched)"
    mkdir -p "$CFG_DIR" "$LOG_DIR"
    cp "$HERE"/../config/*.cfg "$CFG_DIR"/ || die "config copy failed"
}

make_init() {
    local sock_arg="-I /tmp/klippy_uds" api_arg="-a /tmp/klippy.sock"
    local stock_init; stock_init=$(find_stock_init)
    if [ -n "${stock_init:-}" ] && [ -f "$stock_init" ]; then
        local s; s=$(grep -o '\-I [^ ]*' "$stock_init" | head -1)
        local a; a=$(grep -o '\-a [^ ]*' "$stock_init" | head -1)
        [ -n "$s" ] && sock_arg="$s"
        [ -n "$a" ] && api_arg="$a"
    fi
    cat > "$VAN_INIT" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=01
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command $PY $SRC_DIR/klippy/klippy.py $sock_arg $api_arg -c $CFG_DIR/printer.cfg -l $LOG_FILE
    procd_set_param env PYTHONPATH=$DEPS_DIR CC=/opt/bin/gcc PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
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
    say "Waiting up to 90s for 'Printer is ready'"
    i=0
    while [ $i -lt 90 ]; do
        if grep -q "Printer is ready" "$LOG_FILE" 2>/dev/null; then
            say "VANILLA KLIPPER IS UP"
            return 0
        fi
        if grep -qiE "^Config error|Traceback|Unknown config" "$LOG_FILE" 2>/dev/null; then
            return 1
        fi
        sleep 3; i=$((i+3))
    done
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
            say "Done. Fluidd/Mainsail reconnect automatically (same socket)."
            say "Screen (Creality UI) may partially misbehave — stop display-server if so."
            say "Revert anytime: sh $0 revert"
        else
            do_rollback
        fi
        ;;
    *) die "usage: install.sh [install|revert|status|deps]" ;;
esac
