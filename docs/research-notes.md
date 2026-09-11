# Research notes — реверс-инжиниринг K2: что перенесено и что пригодится

Синтез исследования сторонних репозиториев (2026-09-09…11): `grant0013/k2-reverse-engineering`,
`Jacob10383/*` (20 репо), `KalicoCrew/kalico`, `gitstonelabs/creality-klipper-unlocked`,
`CrealityOfficial/K2_Series_Klipper`. Цель — кормовая база для k2-vanilla
(upstream klipper3d v0.13.0, стоковые GD32-прошивки, сток-хост). Формат: факты +
что уже у нас + что взять в будущем.

## 1. Провенанс K2-extras (важная поправка)

- **`KalicoCrew/kalico` не содержит ни одного K2-extra** — чистый форк Klipper
  (полезен только как апстрим-база: _indx, z_tilt_ng, load_cell и пр.).
- **`Jacob10383/kalico` тоже не содержит motor_control/serial_485/prtouch/box**
  (проверено полным деревом). Его дельта к апстриму — 20 файлов: `config/k2/`
  (полный printer.cfg + макросы), переписанные `klippy/extras/lis2dw.py` (шим
  под старый протокол nozzle-MCU) и `klippy/extras/homing.py` (session API:
  recover_kinematic_faults, G28-машина). `homing.py` делает
  `from .motor_control import ...` — модули он берёт извне.
- Открытые Python-реимплементации `.so`-обвязок живут в:
  **`Jacob10383/k2-plus-custom-firmware` `extras/`** (v6.18: motor_control.py
  185 КБ, motor_map.json 322 КБ, box_protocol.py, prtouch.py, z_align.py,
  power_loss_recovery.py, external_rfid_reader.py…) и
  **`gitstonelabs/creality-klipper-unlocked`** (motor_control 85 КБ,
  serial_485 63 КБ, prtouch_v3 80 КБ, box, auto_addr, z_align — wire-валидация).
  Официальный сток (заглушки-шимы + настоящие `.so`) —
  `CrealityOfficial/K2_Series_Klipper`; адаптация под mainline — референс
  `grant0013/K2-OpenKlipper` (решение по нему — см. stage1-log).
- **Следствие**: периодически диффать наши `files/*.py` с
  `k2-plus-custom-firmware/extras` v6.18 и gitstonelabs — там фиксы,
  которых у нас может не быть.

## 2. RS-485 протокол (проверено против наших files/)

Кадр: `[0xF7][addr][len=len(data)+3][status][func][data][CRC8]`;
CRC-8 poly 0x07 init 0 по `[len..data]` — в коммит-месседже стока совпадает с
`msgblock_485_crc8()`; наш `files/serial_485.py` (PACK_HEAD 0xF7, poly 0x07) —
✓ совпадает. Шина 230400 бод: ttyS7 main MCU, ttyS1 nozzle MCU, ttyS5 RS-485
(CFS/box). Адреса: X=0x81, Y=0x82, Z=0x83, Z1=0x84, E=0x85; X/Y/Z/Z1 — через
transparent main MCU, **E — через transparent nozzle MCU (не serial_485)**;
CFS-боксы — **0x01–0x04** (не 0x10–0x14!), belt-натяжители 0x21/0x22,
broadcast 0xFE/0xFF. Функции моторов: 0x01 reboot, 0x03 encoder_cal,
0x04 elec_offset_cal, 0x05 control, 0x06 sys_param, 0x07 flash_param, 0x08 get,
0x0B boot, **0x0C protection**, 0x0D systemid, 0x0E read/set_addr, 0x0F version,
**0x11 stall_mode**, 0x12 dev_uuid. Коды CFS (наш box_protocol.py — ✓ 1:1):
0x02 RFID_RECORDS, 0x03 RFID_REMAINING, 0x04 TRACKING, 0x05 BUFFER,
0x08 SLOT_MASK, 0x0A BOX_STATE, 0x0D RFID_CONTROL, 0x0E ENCODER, 0x10 LOAD,
0x11 UNLOAD, 0xA0/A1/A2 assign/discover/hw_status; статусы 0x00 OK …
0x50 RUNOUT. RFID: чтение записей 0x02, остаток 0x03, управление 0x0D
(детали кадров в k2-plus-custom-firmware `box_protocol.py`/`external_rfid_reader.py`).

Ключевые факты по 0x0C:
- чтение = `ADDR 0x0C 0x0B` → 8-байтный блок, **все нули = здоров**; 16 кодов
  ошибок мапятся на биты (бит-порядок в портах помечен непроверенным); у нас
  `decode_protection_payload` + `EXCESSIVE_POS_TRACKING_ERROR` = бит 8;
- clear = `ADDR 0x0C 0x05` — **сток шлёт его «вслепую», устройство не отвечает
  by design**; пропавший ответ на 0x05 — не потерянный полл (наш
  `protection_clear` no-ack — корректен);
- timeout-класс стока 2000 мс, retries 4; быстрая проверка 50 мс;
- **стоковый wrapper `cmd_send_data_with_response` виснет на `completion.wait()`
  без waketime** — пропавший ответ = вечное ожидание. Наш serial_485 уже
  deadline-based (`_wait_for_response` → None, retries в `_process_request`) —
  ничего переносить не нужно.

Столл-режим 0x11: DATA=1 arm (G28, X и Y, ~19 мс между), DATA=2 disarm
(всегда, обе оси), DATA=3 arm для cut-cal (только X=0x81); устройство отвечает
эхом байта. **Противоречие с нашим выводом «Y-драйвер не имеет 0x11»** (коммит
ce02622, param-write путь — рабочий): wire-капчи стока показывают доставку 0x11
обеим осям. Действие: сверить версию мотор-прошивки через 0x0F (версии моторных
бинов по релизам — в `Jacob10383/Creality-K2Plus-Extracted-Firmwares`,
напр. `mot2_002_081.bin`) — поведение 0x11 может зависеть от версии.

## 3. Параметры защиты/столла (motor_map.json, per-axis)

- `protection_param_prt_track_max_err` — value_id 187 (0xBB), float, дефолт 0.1
  (рад); сток-конфиг F008/V1.1.260206 ставит 0.3; grant0013 даёт raw 1000/800
  (X/Y) — **значения зависят от версии мотор-прошивки**, сверять живьём через
  MOTOR_READ_PARAM, не верить таблицам вслепую.
- `protection_param_prt_track_err_time` — id 188, 0.1 с (трип только если
  ошибка держится 100 мс).
- `protection_param_protect_en` — id 173 (0xAD), uint16, 1=вкл. Диагностическая
  ручка (закомментирована в config/motor_control.cfg).
- Прочие: `prt_peak_cur_A` 0xB3=999 (отключено), `prt_continuous_cur_A` 0xB4=4.0
  @1.0 с, `prt_over_speed_rad_s` 0xB6=100π; столл: `param_stall_mode` id 12
  (2=disarm), `param_stall_cur_A` id 13=0.7, `param_stall_pos_err_rad` id 14
  (дефолт 0.012; наш конфиг 0.007 — жёстче, для сенсорного хоминга),
  `stall_pos_err_rad_for_slicer` id 226=0.016375.
- Zazen (idle-current): `zazen_param_zazen_en` id 217, `…_trigger_time_s` id 218
  (1.0 с), gains 219–223. Гипотеза по ложным idle-трипам: кластеризация вокруг
  момента входа zazen — ручки вынесены в motor_control.cfg (закомментированы).
- Запись параметров: func 0x06 `[0x01, id, f32|int16 LE]` (runtime), apply
  `[0x03]`; чтение `[0x02, id]`; ID в hex — 0x0C, 0x42, 0x43, 0x5E, 0x6E, 0x7A,
  0x80, 0xAD, 0xC8, 0xCC, 0xD9 — int.

## 4. lis2dw — перенесено (W1)

`files/lis2dw.py` — шим из Jacob10383/kalico под старый протокол nozzle-MCU:
`config_lis2dw oid=%d spi_oid=%d`, `query_lis2dw oid=%c clock=%u rest_ticks=%u`
(рестарт с clock=0 rest_ticks=0), стрим `lis2dw_data`, статус
`lis2dw_status … next_sequence=%hu buffered=%c fifo=%c limit_count=%hu`.
Декодинг: 6 Б/сэмпл, 8 сэмплов/блок, ClockSyncRegression; SPI mode 3, 5 МГц,
WHO_AM_I 0x44, CTRL_REG6 0x34, FIFO_CTRL 0xC0, CTRL_REG1 0x94, ODR 1600,
SCALE = 9.80665·1.952/4. Все использованные API сверены с v0.13.0:
`bulk_sensor.BulkDataQueue` (bulk_sensor.py:116), `BatchBulkHelper`,
`ClockSyncRegression`, `adxl345.AccelCommandHelper/AccelQueryHelper`
(1-арг конструктор в v0.13), `read_axes_map`, `bus.MCU_SPI_from_config`,
`MCU_spi.get_command_queue` — совместимо. Апстримный v0.13 lis2dw
(`bus_oid/bus_oid_type`, query без clock) со стоковой GD32 — несовместим
по проводам, потому и шим. Конфиг — из сток-капчи (printer.cfg):
cs nozzle_mcu:PA4, software SPI PA5/PA7/PA6, axes_map x,z,y;
[resonance_tester] 20–120 Гц, accel_per_hz 100, probe_points 130,130,130.
`patch_v013.py` удалён (его анкоры резали бы наш файл; install.sh больше
его не вызывает).

## 5. master-server / экран (перенесено: G29-гвард, W2)

- master-server сам шлёт `G29 BED_TEMP=NN` (Control/PrintfManager.c:604),
  `BED_MESH_CALIBRATE GCODE_FILE=…` (AppModeSdPrint.c:1992, параметр
  игнорируется), `BED_MESH_PROFILE LOAD=default` (AppFuncModule.c:2516),
  `BED_MESH_CLEAR`, `BED_MESH_CALIBRATE_START_PRINT`, `RESTORE_LIMITS/SET_LIMITS`,
  `MOTOR_CONTROL NUM=2 DATA=2`.
- Парсит `[G29_TIME]Execution time: NN seconds` (GcodeCmdResAnl.c:5345) —
  без строки **зависает**; state-переменная `bed_mesh_calibate_state`
  (опечатка в бинарнике) — флаг пропуска калибровки.
- Наша реализация: `[gcode_macro G29]` в macros.cfg — no-op + эмуляция
  handshake через `RESPOND PREFIX=""` (сырая строка без `// `), временный
  passthrough — `SET_G29_PASSTHROUGH VALUE=1`.
- Ловушка стека: секции вида `[bed_mesh_override]` роняют Klipper на старте
  (ProfileManager сплитит имя секции → IndexError). Не создавать такие секции.

## 6. SAVE_CONFIG / bed_mesh (механика стока)

Стоковый bed_mesh.py (1335 строк) **не полагается на SAVE_CONFIG**: конец
`probe_finalize` → `save_profile("default")` → `configfile.set` в
`[bed_mesh default]` → флаш через **`CXSAVE_CONFIG`** (креативовский save без
рестарта klippy); автозагрузка `default` на старте; вебхуки
`get_mesh`/`update_mesh` персистят через CXSAVE_CONFIG;
`BED_MESH_SAVE`/`BED_MESH_RESTORE` — только in-memory.
Наши выводы согласуются: SAVE_CONFIG у нас mesh-профили не переживает
(подтверждено) — профиль живёт в `config/mesh.cfg` (hand-carried),
загрузка в homing_override/START_PRINT через `BED_MESH_PROFILE LOAD=default`
(сток перед печатью тоже грузит, не строит — print-flow-playbook).
Опция на будущее: температурные профили `_CREATE_MESH`/`MESH_IF_NEEDED`
(k2-improvements, профиль `"<bed_temp>c_<chamber_temp>c"` + heat-soak) —
если начнём замечать дрейф первого слоя от температуры стола.

## 7. prtouch (факты для prtouch_mainline/альтернатив)

CS1237 на nozzle MCU (`pres_cfg_regs=60`, 1280 Гц); шаги — main MCU; реальный
останов Z — **endstop main-MCU PC7 через trsync** (nozzle PA15 → PC7),
`stop_prtouch_pres sta_swap=1` сбрасывает latch (лекарство от
«Probe triggered prior to movement»); пороги `pres_tri_hold: 4000,10000,500`,
`lmt_dead=128`, фильтры ned_tftr=5/hftr=1000/lftr=800, pi_count=64; G28-retry:
до 20 попыток, сходимость 3 замеров в 0.5 мм. На хосте `PRES_CHECK` — заглушка,
логика в nozzle-fw.

## 8. trsync / ядро

- kalico `danger_options multi_mcu_trsync_timeout: .1` — релевантно нашему
  TRSYNC_TIMEOUT-патчу (install.sh уже ставит 0.05 для mcu.py).
- Старые сигнатуры эпохи GD32-fw: `setup_adc_callback(report_time, callback)`,
  `buttons.py` без `register_debounce_button` — если портируем свежие апстрим
  модули, сверять сигнатуры.
- `statistics.py` стока затеняет stdlib и ломает `.so`-вызовы
  `statistics.median()` — не наш случай (ваниль), но помнить при диффах.

## 9. Что ещё можно взять позже (бэклог)

- **homing.py из Jacob10383/kalico** — референс сессийной машины G28
  (protection query data=11 / clear data=5 перед хоумингом, retrigger-delta,
  XY-startup-prime 0.1 мм @20 мм/с). У нас то же самое сделано макросами +
  MOTOR_CHECK_PROTECTION_AFTER_HOME; при усложнении хоуминга — источник идей.
- **resonance_tester-патч** (интеграл свипа для suspend_limits) и
  **klippain-shaketune** (форк уже с max_accel_to_decel-фиксом e2003a0f) —
  после первого живого SHAPER_CALIBRATE.
- **Nozzle-камера**: `k2-nozzlecam` — готовый рецепт под сток (hotplug `60-v4l`
  разделение камер, ustreamer :8081, Fluidd-макросы v4l2-ctl).
- **Cartographer** (форк `cartographer3d-plugin`, коммит 9e6930ba «Full K2
  Port») — только как железный апгрейд; требует Y-endstop spacer 5.8 мм.
- **Сток-конфиги F021** в `Creality-K2Plus-Extracted-Firmwares`
  (`config/F021_*/printer.cfg` и др., 19 версий хост-fw 1.1.0.57…1.1.6.4) —
  эталон пинов/параметров именно нашей платы; там же все GD32-бины.
- Не брать: helixscreen (чистый форк), cartographer-klipper (апстрим-копия),
  KalicoCrew/kalico как источник K2-кода.

## 10. Что перенесено в этом цикле

| Фикс | Файлы | Статус |
|---|---|---|
| lis2dw shim (старые сигнатуры, W1) | files/lis2dw.py, удалён files/patch_v013.py, scripts/install.sh, config/printer.cfg, README* | перенесено, живой тест SHAPER_CALIBRATE — на пользователе |
| G29-гвард (W2) | config/macros.cfg ([gcode_macro G29], SET_G29_PASSTHROUGH) | перенесено |
| protection poll knob + протокольные заметки (W3) | files/motor_control.py, config/motor_control.cfg | перенесено |
| Синтез реверса (W4) | docs/research-notes.md (этот файл), roadmap, stage1-log | перенесено |
