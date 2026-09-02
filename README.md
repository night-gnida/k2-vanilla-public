# k2-vanilla — Upstream Klipper for the Creality K2 (base, F021)

[English](README.md) | [Русский](README_RU.md)

Run the **original klipper3d/klipper host** on a Creality K2 base printer,
replacing Creality's stale Klipper fork — while keeping the stock Creality OS
and the stock MCU firmware. Bed auto-leveling (load-cell "PRTouch") and the
CFS filament system keep working through open-source reimplementations.

> **Status: experimental.** The kit is built and validated offline (config
> cross-checked against upstream sources, install script syntax-checked), but
> it has **not yet run on live hardware**. The installer auto-rolls-back to
> stock if the new host fails to start.

---

## 1. How it works

```
┌────────────────────────── K2 mainboard ──────────────────────────┐
│  Allwinner T113-i host (stock OpenWrt/Tina, root)                │
│    ├─ klippy  ← UPSTREAM klipper3d (tag v0.13.0), built on-      │
│    │            printer via Entware gcc (c_helper.so)            │
│    ├─ 12 vendored K2 modules (GPL-3, from Jacob10383/kalico):    │
│    │   prtouch (load-cell probe), serial_485, motor_control,     │
│    │   box×5 (CFS), motion_limits, force_stop_homing,            │
│    │   led_idle_manager, power_loss_recovery                     │
│    ├─ Moonraker (STOCK, untouched — same socket, Fluidd just     │
│    │            reconnects)                                      │
│    └─ Creality screen / display-server (left alone; see §9)      │
│  MCU boards: STOCK Creality firmware — never reflashed.          │
│    Host↔MCU protocol is negotiated at connect; a modern host     │
│    talking to these MCUs is proven by the Jacob10383 stack.      │
└──────────────────────────────────────────────────────────────────┘
```

Why this is possible: the K2-specific modules written for Kalico use **zero**
Kalico-only APIs (audited: no `danger_options`, self-contained imports, core
API calls identical to upstream). They drop into klipper3d unchanged.

## 2. What you gain / lose

**Gain**
- Original, current upstream Klipper (tag configurable, default `v0.13.0` —
  the newest upstream release tag).
- Open-source replacements for everything Creality kept closed: bed probing,
  CFS, closed-loop motor tuning hooks.
- Update path = ordinary `git`/tarball bump; no closed blobs.

**Kept**
- Stock OS, stock MCU firmware, stock Moonraker/Fluidd (:4408), stock config
  directory untouched (new configs live in `config-vanilla/`).
- One-command rollback to stock klippy at any time.

**Lose / caveats**
- The Creality touchscreen may misbehave (its display-server expects the
  forked klippy). If it does: stop `display-server`, use Fluidd/Mainsail or
  [HelixScreen](https://helixscreen.org).
- KAMP and timelapse are not included yet.
- Power-loss recovery is the Kalico implementation (upstream has none) —
  vendored here, but it is less battle-tested on this printer.
- Chamber-heater macros (`M141`/`M191`) are no-ops that answer "no chamber
  heater". If you later physically add the K2 Pro PTC unit (same board
  circuits exist), rework these macros to the Pro variant.

## 3. Repository layout

```
k2-vanilla/
├── README.md            this file (EN)
├── README_RU.md         Russian version
├── LICENSE              GPL-3.0
├── files/               12 vendored klippy extras (GPL-3, unmodified)
├── config/              printer.cfg, prtouch.cfg, box.cfg, macros.cfg,
│                        start_print.cfg, overrides.cfg, motor_control.cfg
└── scripts/install.sh   install / switch / revert / status (runs on printer)
```

Vendored modules (all GPLv3, from [Jacob10383/kalico](https://github.com/Jacob10383/kalico),
unmodified): `prtouch.py`, `serial_485.py`, `motor_control.py`, `box.py`,
`box_addr.py`, `box_catalog.py`, `box_change.py`, `box_protocol.py`,
`motion_limits.py`, `force_stop_homing.py`, `led_idle_manager.py`,
`power_loss_recovery.py`.

## 4. Requirements

- Creality **K2 base (F021)** on **stock firmware**, root access enabled
  (printer menu → Root account → user `root`, password `creality_2024`).
- **Entware** installed on the printer (provides gcc, make, python3, pip).
- Internet on the printer (downloads the Klipper tarball from codeload.github.com).
- The stock klipper init script present (`/etc/init.d/klipper` or similar).

The kit is built for the base model (F021: 260×260 mm bed, single Z with
64:20 gearbox, TMC2208 on PC1, no chamber heater). K2 Pro shares the board
but not the geometry — do not use as-is.

## 5. Installation

**On the PC** (the repo is private — the printer cannot fetch it):

```bash
scp -r k2-vanilla root@<PRINTER_IP>:/mnt/UDISK/k2setup/
```

**On the printer** (SSH as root):

```bash
sh /mnt/UDISK/k2setup/k2-vanilla/scripts/install.sh
```

What the script does, in order:

1. Installs Entware packages: `gcc make python3 python3-pip python3-dev libstdc++`.
2. `pip install --target /mnt/UDISK/klipper-vanilla-deps greenlet` (no venv —
   Entware python is used directly).
3. Downloads the Klipper source tarball and extracts it to
   `/mnt/UDISK/klipper-vanilla`. Pin a version with
   `K2_VANILLA_KLIPPER_TAG=vX.Y.Z` (default `v0.13.0`).
4. Copies `files/*.py` into `klippy/extras/` (vendored modules).
5. Copies `config/*.cfg` to `/mnt/UDISK/printer_data/config-vanilla/` — the
   stock config directory is **not** touched.
6. Detects the socket arguments (`-I`, `-a`) from the stock klipper init
   script so Moonraker/Fluidd reconnect transparently.
7. Creates a procd service `/etc/init.d/klipper-vanilla`, disables the stock
   klipper service, starts vanilla.
8. Waits up to 90 s for `Printer is ready` in the log. On a config error or
   timeout it **automatically rolls back** to stock and prints the log tail.

On success: `VANILLA KLIPPER IS UP`. Fluidd reconnects on its own.

## 6. Switching and rollback

```bash
sh .../install.sh status     # what is currently active
sh .../install.sh revert     # back to stock Creality klippy (vanilla files kept)
```

`revert` re-enables the stock service and starts it; vanilla files stay on
`/mnt/UDISK` for a later retry and can be deleted manually.

## 7. First motion — safety checklist

Keep a hand on the power switch for the first runs:

1. Home X/Y — head moves left/back to endstops PB11/PB12 at low speed.
2. `G28 Z` — nozzle travels to bed center (130,130) and **slowly** probes with
   the load cell. This is the first live test of PRTouch on upstream Klipper.
3. Check fans/LED react sensibly.

If anything moves the wrong way — cut power; nothing is saved that matters.

## 8. Hardware verification and calibration

- **Probe**: run `PROBE` a few times — spread should be in the hundredths of mm.
- **CFS**: the box must appear in Fluidd (`box_count: 1`). Try load/unload.
  **`CALIBRATE_CUT_POS` is mandatory before the first filament change.**
- **Coordinates marked `VERIFY`** in `box.cfg` (pad edges and wastebin are
  derived from factory values but need an on-printer eye):

  | Parameter | Value | Source |
  |---|---|---|
  | `clean_pad_left_x` / `right_x` | 127 / 137 | factory F021 `box.cfg` |
  | `clean_pad_front_y` / `back_y` | 286.5 / 296.5 | estimated from factory strip middle y=291.5 |
  | `wastebin_pos_x` / `y` | 115 / 294 | factory extrude point, estimated |
  | `cut_pos_y`, `pre_cut_pos_x` | 150 / 10 | factory |
  | cutter calibration window | x −5.5…−9.5 | Plus-tested, refine via `CALIBRATE_CUT_POS` |

- **Calibration order** (k3d.tech methodology):
  `SCREWS_TILT_ADJUST` (screws at 30/230) → `BED_MESH_CALIBRATE
  PROFILE=default` → `PROBE_CALIBRATE` → `BEDPID` + `NOZZLE_PID` → input
  shaper (lis2dw accelerometer) → flow → pressure advance. The extruder is a
  closed-loop unit: run `MOTOR_ENCODER_CALIBRATE` first or PA results will be
  polluted by diagonal artifacts.

## 9. Troubleshooting

| Symptom | Action |
|---|---|
| Installer rolled back | Read the printed klippy log tail; fix `config-vanilla/*.cfg`; rerun `install.sh` (steps are idempotent). |
| greenlet failed to build | Entware python headers missing: `opkg install python3-dev`; check `gcc` present. |
| Fluidd doesn't reconnect | Check the `-I`/`-a` paths the script derived: `grep -E '\-I|\-a' /etc/init.d/klipper-vanilla`; compare with the stock init script and Moonraker's `klippy_uds_path`. |
| Touchscreen glitchy | `/etc/init.d/display-server stop` (service name may differ); use Fluidd or HelixScreen. |
| Printer behaves oddly after a Creality OTA | OTA targets the stock slot/service — run `install.sh status`, re-run install if needed. |

## 10. FAQ

**Why not just replace klippy inside the stock fork?**
The stock host is an old fork (~v0.12) welded to closed blobs: `prtouch_v3`
(.o), RS485 msgblock, EEPROM module, master-server coupling. Upstream cannot
load them; the fork cannot be updated. This kit replaces the host entirely
and reinstates the missing features from open code.

**Why keep MCU firmware stock?**
The whole Klipper brain lives on the host. MCU firmware speaks a
negotiated protocol; reflashing GD32 boards with vanilla builds is risk with
no benefit. Nothing here touches the MCU.

**Why is `[power_loss_recovery]` included if upstream has no such section?**
Upstream klipper3d indeed has **no** PLR module. Kalico's implementation is
vendored (pure upstream-compatible API, audited) so the section in
`printer.cfg` keeps working.

## 11. License and credits

- This project: **GPL-3.0** (see `LICENSE`).
- K2-specific klippy modules: © Jacob10383, GPLv3, from
  [Jacob10383/kalico](https://github.com/Jacob10383/kalico) — vendored
  unmodified.
- [Klipper](https://github.com/Klipper3d/klipper) — GPLv3, © the Klipper
  authors.
- Factory geometry/thermistor data: read from the user's own printer
  firmware (`F021` config, stock V1.1.6.7); no Creality code is redistributed.
- Not affiliated with or endorsed by Creality. Use at your own risk; the
  installer keeps the stock environment switchable at all times.
