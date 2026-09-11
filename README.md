# k2-vanilla — Upstream Klipper for the Creality K2 (base, F021)

[English](README.md) | [Русский](README_RU.md)

Run the **original klipper3d/klipper host** on a Creality K2 base printer,
replacing Creality's stale Klipper fork — while keeping the stock Creality OS
and the stock MCU firmware. Bed auto-leveling (load-cell "PRTouch") and the
CFS filament system keep working through open-source reimplementations.

> **Status: running on hardware, pre-print hardening done.** Vanilla klippy
> reaches `ready` and survives restarts/reinstalls; gentle sensorless homing
> (X/Y stall via runtime motor params) and the PRTouch load-cell probe
> (z_offset −0.07, paper-calibrated) are verified live; the bed mesh
> (11×11) matches the stock-firmware capture within ~6 µm. Config numbers
> follow a live stock-print capture (`docs/print-flow-playbook.md`): input
> shapers 52.4/45.4 MZV, CFS `cut_pos_x −7.8`, mesh-LOAD start flow.
> Works with the **Phaetus DXC-2** extruder mod (5:1 on the stock E servo).
> Next milestone: first full print (master plan: `docs/roadmap.md`).

---

## 1. How it works

```
┌────────────────────────── K2 mainboard ──────────────────────────┐
│  Allwinner T113-i host (stock OpenWrt/Tina, root)                │
│    ├─ klippy  ← UPSTREAM klipper3d (tag configurable, default    │
│    │            v0.13.0), prebuilt cross c_helper.so             │
│    ├─ 12 open K2 driver modules (GPL-3 © Jacob10383):            │
│    │   prtouch (load-cell probe), serial_485, motor_control,     │
│    │   box×5 (CFS), motion_limits, force_stop_homing,            │
│    │   led_idle_manager — all audited upstream-clean             │
│    ├─ Moonraker (STOCK, untouched — same socket, Fluidd just     │
│    │            reconnects)                                      │
│    └─ Creality screen / display-server (left alone; see §2)      │
│  MCU boards: STOCK Creality firmware — never reflashed.          │
└──────────────────────────────────────────────────────────────────┘
```

Why this is possible: the K2-specific modules written for Kalico use **zero**
Kalico-only APIs (audited statically, `scripts/audit_compat.py`). They drop
into klipper3d unchanged. The same "stock OS + stock MCU firmware" approach
is independently validated by grant0013's K2-OpenKlipper, which reached a
32 % Benchy **without patching the klippy core at all** — its stability
recipes (CPU pinning, arc resolution) are adopted here.

## 2. What you gain / lose

**Gain**
- Current upstream Klipper; update = ordinary tarball bump, no closed blobs.
- Installs on **bare stock**: no Entware required (a prebuilt hard-float
  `c_helper.so` ships in `files/`), no `wget` needed, and **offline
  install** from a local Klipper tarball is supported.
- Config numbers taken from a live stock-print capture instead of guesses:
  input shapers 52.4/45.4 MZV, CFS `cut_pos_x −7.8`, bed-PID, mesh grid.
- Stability recipes for this SoC: klippy pinned to the 2nd core (`taskset`),
  `[gcode_arcs] resolution 1.0` (finer arcs caused "Timer too close"
  dual-MCU shutdowns — K2-OpenKlipper finding), config deploy verified
  byte-for-byte before restart (see §9).
- Phaetus **DXC-2** extruder mod supported: slow E-retract velocity for
  unload/cut (per Phaetus requirement), `rotation_distance` calibration
  documented in §8.

**Kept**
- Stock OS, stock MCU firmware, stock Moonraker/Fluidd (:4408), stock config
  directory untouched (new configs live in `config-vanilla/`).
- One-command rollback to stock klippy at any time.

**Lose / caveats**
- The Creality touchscreen may misbehave (its display-server expects the
  forked klippy). If it does: stop `display-server`, use Fluidd/Mainsail or
  [HelixScreen](https://helixscreen.org). Do **not** run screen-side
  calibration while printing — stock `master-server` injects G29/mesh
  commands and expects a `[G29_TIME]` handshake (grant0013's reverse
  engineering).
- Resonance testing: the stock GD32 firmware only speaks the **old**
  lis2dw MCU command signatures (`config_lis2dw oid/spi_oid`,
  `query_lis2dw oid/clock/rest_ticks`), so the kit ships a fork-era
  `files/lis2dw.py` compat shim (replaces the upstream module at install);
  `[lis2dw]` + `[resonance_tester]` are enabled in `printer.cfg` with the
  stock live-capture values. `SHAPER_CALIBRATE`/`TEST_RESONANCES` are
  available — after first live validation the factory shapers (52.4/45.4)
  can be replaced with measured ones.
- No power-loss recovery: upstream has no PLR, and the Kalico module was
  removed from the kit as dead weight (its z_align choreography was
  Plus-specific). An own single-Z PLR is a roadmap item.
- KAMP-style adaptive purge and timelapse are not included yet (roadmap).
- Chamber-heater macros (`M141`/`M191`) are no-ops ("no chamber heater").
  If you later physically add the K2 Pro PTC unit, rework them Pro-style.

## 3. Repository layout

```
k2-vanilla/
├── README.md / README_RU.md   this file (EN / RU)
├── LICENSE                    GPL-3.0
├── files/                     open K2 driver modules (GPL-3),
│                              lis2dw.py (fork-era accel driver), prebuilt
│                              c_helper.so, motor_map.json (485 param map)
├── config/                    printer.cfg, mesh.cfg (bed mesh), prtouch.cfg,
│                              box.cfg, macros.cfg, start_print.cfg,
│                              overrides.cfg, motor_control.cfg
├── scripts/                   install.sh (install/switch/revert/status),
│                              watchdog_loop.sh, remote.py + pr_gcode.py
│                              (PC-side runners), audit_compat.py,
│                              write_mesh_cfg.py
└── docs/                      roadmap.md (MASTER PLAN — stages, decisions,
                               risks), stage1-log.md (live session log),
                               print-flow-playbook.md (stock start-sequence
                               capture), stock-live-printer.cfg +
                               stock-state.json (live captures),
                               compat-report.md
```

Open K2 driver modules — all GPLv3, © Jacob10383, authored for his Kalico
fork and vendored here (in-file comments mark the few local fixes; a static
audit proves zero Kalico-only API usage): `prtouch.py`, `serial_485.py`,
`motor_control.py`, `box.py`, `box_addr.py`, `box_catalog.py`,
`box_change.py`, `box_protocol.py`, `motion_limits.py`,
`force_stop_homing.py`, `led_idle_manager.py`.

## 4. Requirements

- Creality **K2 base (F021)** on **stock firmware**, root access enabled
  (printer menu → Root account → user `root`, password `creality_2024`).
- The stock klipper init script present (`/etc/init.d/klipper` or similar).
- Entware is **optional** — it is only used to rebuild `c_helper.so`
  on-printer when the shipped prebuilt one does not fit your firmware.
- Internet on the printer is **optional** — the installer accepts a local
  tarball at `/mnt/UDISK/k2setup/klipper-<TAG>.tar.gz` (or
  `K2_VANILLA_TARBALL=...`), otherwise it downloads from codeload.github.com.

The kit is built for the base model (F021: 260×260 mm bed, single Z with
64:20 gearbox, TMC2208 on PC1, no chamber heater). K2 Pro shares the board
but not the geometry — do not use as-is.

## 5. Installation

**On the PC** (the repo is private — the printer cannot fetch it):

```bash
scp -r k2-vanilla root@<PRINTER_IP>:/mnt/UDISK/k2setup/
# optional, for offline install:
scp klipper-0.13.0.tar.gz root@<PRINTER_IP>:/mnt/UDISK/k2setup/
```

**On the printer** (SSH as root):

```bash
sh /mnt/UDISK/k2setup/k2-vanilla/scripts/install.sh
```

What the script does, in order:

1. Checks the stock `klippy-env` python (has cffi+greenlet already) and, if
   Entware is present, its gcc/make (needed only without the prebuilt
   `c_helper.so`).
2. Extracts the Klipper tree to `/mnt/UDISK/klipper-vanilla` — from the
   local tarball if present, else downloads it (`K2_VANILLA_KLIPPER_TAG`,
   default `v0.13.0`).
3. Copies `files/*.py` into `klippy/extras/` (incl. the fork-era
   `lis2dw.py` accel driver for the stock GD32 fw) and applies host patches:
   musl `can.h` include, LTO removal (Entware builds), `TRSYNC_TIMEOUT`
   0.025→0.05, serialhdl connect budgets 90→300 s / 5→15 s.
4. Installs the prebuilt cross-compiled `c_helper.so` (armhf, glibc 2.29 —
   built with Zig; no on-printer compile needed).
5. Copies `config/*.cfg` to `/mnt/UDISK/printer_data/config-vanilla/` and
   **verifies every file byte-for-byte** — this UDISK's NAND can serve
   stale page mixes for minutes after an overwrite (§9).
6. Creates a procd service `/etc/init.d/klipper-vanilla` (klippy pinned to
   the 2nd core via `taskset`), disables the stock klipper service, restarts
   the `klipper_mcu` daemon (better-init recipe), starts vanilla.
7. Installs a watchdog (`k2van-watchdog`): repeated Moonraker connect
   failures → mcu_reset + service restart.
8. Waits up to 420 s for `klippy_state=ready` (transient tracebacks during
   the first-run CRC dance are normal). On failure it **automatically rolls
   back** to stock and prints the log tail.

On success: `VANILLA KLIPPER IS UP`. Fluidd reconnects on its own.

## 6. Switching and rollback

```bash
sh .../install.sh status     # what is currently active
sh .../install.sh revert     # back to stock Creality klippy (vanilla files kept)
```

`revert` re-enables the stock service and starts it; vanilla files stay on
`/mnt/UDISK` for a later retry and can be deleted manually.

Gotcha learned the hard way: never switch services with `killall klippy.py`
— the process name is `python`, the kill is a no-op, and the old instance
keeps the API socket while a second one idles (Moonraker then answers from
the wrong firmware). Use the init scripts / the installer only.

## 7. First motion — safety checklist

Keep a hand on the power switch for the first runs:

1. Home X/Y — head moves left/back to the stall endstops (PB11/PB12) with
   stall-mode delivered via runtime motor params (the Y driver lacks the
   direct command; a param-write path with retries is used).
2. `G28 Z` — the **bed** moves up to the nozzle at bed center (130,130) and
   the load cell stops it softly. Note: on this printer Z moves the bed, not
   the head.
3. A flaky `Endstop ... still triggered after retract` right after boot is a
   known 485-bus glitch — `FIRMWARE_RESTART` and re-home; it does not
   indicate damage.

## 8. Hardware verification and calibration

Verified live so far: PRTouch probe (spread in hundredths of mm;
z_offset −0.07 by the paper method), gentle full G28, CFS box online
(`box_count: 1`), bed mesh 11×11 matching the stock capture within ~6 µm,
bed/heater PID from the stock capture.

- **Bed mesh**: `BED_MESH_CALIBRATE PROFILE=default`, then copy the profile
  into `config/mesh.cfg` (SAVE_CONFIG persistence is a known open issue —
  §9). `START_PRINT` loads `mesh.cfg`'s `default` automatically and only
  re-probes with `ADAPTIVE=1`.
- **Extruder (Phaetus DXC-2)**: the stock closed-loop E servo stays; the
  5:1 gearbox changes `rotation_distance` (stock value 6.9 as the starting
  point — calibrate with a 100 mm extrusion test at 240 °C before the first
  print). Unload/cut retracts run at 60 mm/min per Phaetus' requirement
  (`retract_velocity` in `box.cfg`). Re-tune pressure advance afterwards.
- **CFS**: `CALIBRATE_CUT_POS` is mandatory before the first filament
  change. Coordinates marked `VERIFY` in `box.cfg` (pad edges, wastebin)
  still need an on-printer eye; `cut_pos_x −7.8` is from the live stock
  SAVE_CONFIG and is already applied.
- **Motor protection**: `motor_control.cfg` writes
  `prt_track_max_err = 0.3` for X/Y, while the motors' factory defaults are
  1000/800 raw (ID 39, see grant0013's motor-params map). Verifying/aligning
  this threshold is a pre-print step — false protection trips hard-halt the
  main GD32 until a power cycle.
- **Calibration order** (k3d.tech methodology): `SCREWS_TILT_ADJUST`
  (screws at 30/230) → mesh → `PROBE_CALIBRATE` → `BEDPID` + `NOZZLE_PID`
  → input shaper (blocked, see §2) → flow → pressure advance.

## 9. Troubleshooting

| Symptom | Action |
|---|---|
| "My config does not apply" while files look right on disk | Two klippy instances fought for the socket (e.g. after an installer rollback) — restart via the init script, verify a marker value that only vanilla has (`gcode_arcs resolution 1.0`). `killall klippy.py` does NOT work (process name is `python`). |
| Klippy parses a config that is half old, half new | This UDISK's NAND serves stale page mixes for minutes after an in-place overwrite. Deploy changed files under a NEW name (like `mesh.cfg`), or wait and verify md5 before restarting; `install.sh` now does this automatically. |
| Installer rolled back | Read the printed klippy log tail; fix `config-vanilla/*.cfg`; rerun `install.sh` (steps are idempotent). |
| `Endstop ... still triggered after retract` on G28 | Known 485-bus glitch, most often right after boot — `FIRMWARE_RESTART`, re-home. |
| Klippy went ready → dead, SSH also dead; recovers only by power cycle | A motor protection trip hard-halts the main GD32 (for ANY host, stock included). Check for the false-trip causes in §8 before long prints. |
| `Timer too close` / `Stepper too far in past` | Keep `[gcode_arcs] resolution 1.0`; make sure klippy runs under `taskset` (the installer sets it up). |
| Fluidd doesn't reconnect | Check `-a` in `/etc/init.d/klipper-vanilla`; compare with Moonraker's `klippy_uds_path`. |
| Touchscreen glitchy | `/etc/init.d/display-server stop` (service name may differ); use Fluidd or HelixScreen. |
| Printer behaves oddly after a Creality OTA | OTA resets/removes parts of the system (Entware, /opt, custom trees) — re-run `install.sh`; check `install.sh status`. |

## 10. FAQ

**Why not just replace klippy inside the stock fork?**
The stock host is an old fork (~v0.12) welded to closed blobs: `prtouch_v3`
(.o), RS485 msgblock, EEPROM module, master-server coupling. Upstream cannot
load them; the fork cannot be updated. This kit replaces the host entirely
and reinstates the missing features from open code.

**Why keep MCU firmware stock?**
The whole Klipper brain lives on the host. MCU firmware speaks a
negotiated protocol; reflashing GD32 boards with vanilla builds is risk with
no benefit. Nothing here touches the MCU. (grant0013's K2-OpenKlipper and
Jacob10383's stack make the same choice.)

**Is this a Kalico build?**
No — the host is upstream klipper3d, period. The only Kalico connection is
the birthplace of the driver modules: they were authored by Jacob10383 for
his Kalico fork and are vendored here after a static audit proved they use
zero Kalico-only APIs. (Kalico's PLR module was removed from the kit
entirely — it was never enabled on the base.)

**How does this differ from Jacob10383's K2 Plus custom firmware or
grant0013's K2-OpenKlipper?**
Same philosophy — stock OS + stock MCU firmware, open klippy extras — but
this kit targets the **base F021** model, keeps the stock Moonraker/Fluidd
instead of shipping new ones, and works fully offline. Ideas flow both ways:
the CPU-pinning and arc-resolution recipes come from K2-OpenKlipper; the
motor-parameter and master-server facts come from grant0013's
k2-reverse-engineering; the CFS/probe modules are Jacob10383's.

## 11. License and credits

- This project: **GPL-3.0** (see `LICENSE`).
- K2-specific klippy modules: © Jacob10383, GPLv3, from
  [Jacob10383/kalico](https://github.com/Jacob10383/kalico) — vendored
  (see in-file comments for local fixes); docs:
  [jacob10383.github.io/k2-plus-custom-firmware](https://jacob10383.github.io/k2-plus-custom-firmware/).
- [grant0013/K2-OpenKlipper](https://github.com/grant0013/K2-OpenKlipper) —
  stability recipes (CPU pinning, arc resolution), lis2dw-era insights.
- [grant0013/k2-reverse-engineering](https://github.com/grant0013/k2-reverse-engineering)
  — RS-485 motor protocol and parameter map, master-server/G29 facts.
- [Klipper](https://github.com/Klipper3d/klipper) — GPLv3, © the Klipper
  authors; fork reference: [CrealityOfficial/K2_Series_Klipper](https://github.com/CrealityOfficial/K2_Series_Klipper).
- [Phaetus DXC-2](https://github.com/Phaetus/DXC-2-Extruder) — extruder-mod
  requirements (slow retracts).
- Factory geometry/thermistor data: read from the user's own printer
  firmware (`F021` config, stock V1.1.6.7); no Creality code is redistributed.
- Not affiliated with or endorsed by Creality. Use at your own risk; the
  installer keeps the stock environment switchable at all times.

## Support

If this kit saved you time, tips are appreciated:

- **Bitcoin (BTC)**: `bc1q8u04xphssp6qs0mc5ssk45mlgl7q04mjd35yqp2vurgkwdgehchsw39ge0`
