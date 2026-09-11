# Чек-лист первой полной печати (Этап 1.3) — актуализирован 2026-09-09

Режим «гибрид»: по SSH без вопросов — статус, деплой файлов, рестарт klipper
через procd. Любое движение / нагрев / старт печати — только после явного ОК.
Инструменты: `python scripts/remote.py {exec|push}` с ПК +
`/usr/bin/python3 /tmp/g.py {gcode|get}` на принтере (копия хелпера:
`/mnt/UDISK/k2setup/pr_gcode.py` — push всегда сохраняет ЛОКАЛЬНОЕ имя
файла, `g.py` создаётся ручным cp).

## 0. Предусловия

- Принтер включён, в сети (`ping 192.168.1.10`), SSH отвечает.
- На принтере vanilla: `sh /mnt/UDISK/k2setup/k2-vanilla/scripts/install.sh status`
  → `active: VANILLA klipper`. Проверка-маркер (только у ванили):
  `gcode get configfile` → `gcode_arcs.resolution = 1.0`. Если нет —
  сокет держит чужой klippy (zombie): рестарт ТОЛЬКО через
  `/etc/init.d/klipper-vanilla restart` (killall klippy.py не работает —
  comm = «python»).
- Filament загружен в CFS-слот, сопло чистое, DXC-2 собран.

## 1. Деплой обновлений (я, без ОК)

```bash
export MSYS_NO_PATHCONV=1   # Git Bash иначе портит /mnt/... пути
python scripts/remote.py push config/printer.cfg /mnt/UDISK/k2setup/k2-vanilla/config/printer.cfg
python scripts/remote.py push config/<файл>.cfg   /mnt/UDISK/printer_data/config-vanilla/<файл>.cfg
# ... по файлу; push目录 целиком кладёт плоско — тоже ок
python scripts/remote.py exec "sync; /etc/init.d/klipper-vanilla restart"
```

ВАЖНО (UDISK FTL): после перезаписи конфига klippy может прочитать смесь
старых/новых страниц. Перед рестартом — `sync`, пауза ~30 c, сверка md5;
изменяемые данные (меш) — под НОВЫМ именем файла (как `mesh.cfg`).
Для полного пере-деплоя используйте сам `install.sh install` — его do_config
теперь верифицирует md5 каждой копии.

Верификация после рестарта (маркеры, которые есть только у ванили):
`arcs = 1.0`, `retract_velocity = 60`, `mesh profiles: ['default']`.

## 2. Калибровка rotation_distance DXC-2 (по ОК, ~7 мин)

1. `G28` (мягкий) → `G1 Z10 F600` → `BOX_GO_TO_WASTEBIN` (за кромку стола).
2. `M104 S240` + `TEMPERATURE_WAIT SENSOR=extruder MINIMUM=235` + dwell 8 c.
3. Продув: `G92 E0`; `G1 E50 F300` — в урну.
4. Юзер ставит метку на филаменте у входа DXC-2 → `G92 E0`; `G1 E100 F600`.
5. Юзер меряет фактическую длину L от метки до входа.
6. `rotation_distance_new = 6.9 × 100 / L` → правка [extruder], деплой,
   рестарт, контрольный повтор 100 мм (сходимость ±2 %).

## 3. Сверка защиты моторов (по ОК)

1. `MOTOR_READ_PARAM PARAM=x_protection_param_prt_track_max_err` (+y) —
   что реально в моторах: наш 0.3 или заводские (ID 39: X=1000/Y=800 raw)?
2. Сверка с заводским F021 motor_control.cfg (K2_Series_Klipper + rootfs
   V1.1.6.7 в toolchain). При расхождении — выставить сток через
   param-write (проверенный путь) — защита от ложных трипов (GD32 при
   трипе халтится до power-cycle).
3. `MOTOR_CLEAR_ERROR`, 2–3 тестовых G1 + M84.
4. Юзер глазами: ремень/шкив X (после удара о раму 09-03).

## 4. Чистка (по ОК)

`M104 S140` → TEMPERATURE_WAIT → `G28` → `NOZZLE_CLEAN` (обёртка поднимет
Z на 5 мм сама; смотреть траекторию пада — VERIFY 286.5/296.5) →
`PRTOUCH_SCRUB` вручную (из START_PRINT scrub убран — преднатяг тензодатчика
давал ложные «No trigger on z»).

## 5. Benchy PETG (по ОК)

- Orca 2.4+, нативный профиль «Creality K2» (260³, accel 20000).
- Машинный старт: `START_PRINT EXTRUDER_TEMP=240 BED_TEMP=70 MATERIAL=PETG`;
  конец: `END_PRINT`.
- Заливка gcode через Fluidd (:4408) или scp в
  `/mnt/UDISK/printer_data/gcodes/`.
- Старт, контроль первых 2–3 слоёв живьём, печать до конца, осмотр.
- Контингенции: старт печати висит >20 c → шим update_manager из
  K2-OpenKlipper; 485-потери → ретраи в коде; GD32-халт → power cycle,
  разбор причин перед повтором.

## 6. Фиксация

- Успех → README (оба) статус «physically validated» с датой/моделью/
  пластиком; stage1-log дописать; roadmap Этап 1 закрыть.
- Любая правка конфига на принтере → sync-back в репо (профили меша — в
  mesh.cfg).
