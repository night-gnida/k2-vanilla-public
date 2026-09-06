# Playbook: стоковая последовательность печати → ванильные эквиваленты

Захвачено из живого лога стока (V1.1.260206) во время реальной печати PETG
(Mighty, 4ч), 2026-09-06, + штатный live-конфиг стока (docs/stock-live-printer.cfg).

## Рестарт-факт: сетка

- **Перед обычной печатью сток НЕ строит сетку** — он грузит сохранённый профиль:
  `BED_MESH_PROFILE LOAD="default"` (после каждого BED_MESH_CLEAR).
- Сток прогоняет полную калибровку сетки (76 тапов) только при явной калибровке
  из UI (G29 / автокалибровка) — это отдельная процедура, не старт печати.
- Вывод для ванилы: наш START_PRINT с ADAPTIVE=1 пересчитывает сетку каждый
  раз — медленнее стока. Быстрый вариант: BED_MESH_PROFILE LOAD=default +
  опционально adaptive. **Убедиться, что профиль default сохранён** (проблема
  SAVE_CONFIG — ниже).

## Полная стоковая последовательность старта печати (хронология 19:53–19:59)

```
# подготовительная фаза (после G28 XYZ где-то раньше)
G28 Z
BED_MESH_CLEAR
BED_MESH_PROFILE LOAD="default"
BOX_GO_TO_EXTRUDE_POS            # парковка у CFS-экструзионной точки
BOX_NOZZLE_CLEAN                 # чистка сопла
G28 Z                            # повторный Z после чистки!
BED_MESH_CLEAR + LOAD=default    # (сброс+загрузка, штатная их манера)
SET_LIMITS                       # fork: временные лимиты для сервисной зоны
G1 X197..206 Y265.5 Z5.0..5.3    # ТОЧКИ ОБТИРА у задней панели (Y>260 — сервисная зона!)
SET_VELOCITY_LIMIT ACCEL=5000 ACCEL_TO_DECEL=5000 VELOCITY=800
M104 S0                          # сопло сброс (уже горячее от подготовки)
BED_MESH_CLEAR + LOAD=default
BOX_GO_TO_EXTRUDE_POS
M104 S180 ; TEMPERATURE_WAIT extruder 175..185   # промежуточный прогрев
BOX_NOZZLE_CLEAN
SET_LIMITS
G1 X78.73 Y265.5 Z5.0 / Z2.28    # ещё точки обтира (у CFS-зоны)
G1 X160 Y265.5 Z-0.31            # опускание ниже нуля — ход по сервисной зоне
M106 S127 ; M106 P2 S255         # вентиляторы на обдув
M109 S170                        # ждать 170
BOX_GO_TO_EXTRUDE_POS
SET_LIMITS
M109 S140                        # ждать 140 (хоминговая температура)
G1 X180 Y265.5 Z5
SET_VELOCITY_LIMIT (5000)
BOX_GO_TO_EXTRUDE_POS
BOX_NOZZLE_CLEAN
RESTORE_LIMITS
BED_MESH_PROFILE LOAD="default"
G1 X130 Y130 Z5 / Z1             # проезд в центр
BED_MESH_PROFILE LOAD="default"
SET_VELOCITY_LIMIT ACCEL=20000 ACCEL_TO_DECEL=20000   # боевой разгон
# heat-soak зигзаг над столом:
G1 X230 Y80 / X205 / X180 / X155 / X130 / X105 / X80 / X55 / X30 (Y80, Z1.0)
# затем sliced M73/M106/M141 S35/M140 S0/M104 S0 + сам START_PRINT из слайсера:
START_PRINT EXTRUDER_TEMP=250 BED_TEMP=70
T0; M104 S250; M204 S2000; G1 Z3; M83; G1 X105 Y-1 F30000; продув G1 X130..155 E...
G91; G1 X1 Z-0.3; G1 X4; G92 E0  # сдвиг после продува
```

## Прочие стоковые команды во время печати (CFS-фоновая работа)

- `SET_PRE_LOADING`, `TIGHTEN_UP_ENABLE` — предзагрузка/натяжение перед стартом.
- `SET_BOX_MODE` ×2, `EXTRUDE_PROCESS` ×8 — CFS-продув/подготовка при старте.
- `MEASURING_WHEEL` ×44+ — измерение расхода филамента (периодически).
- `GET_REMAIN_LEN`, `GET_FILAMENT_SENSOR_STATE`, `GET_BUFFER_STATE`,
  `GET_BOX_STATE` (74 раза!) — фоновый поллинг CFS каждые ~4 с.
- `T1D` — активный слот материала.

## Критичные числа из живого стокового конфига (SAVE_CONFIG)

| Параметр | Значение | Наш статус |
|---|---|---|
| `box cut_pos_x` | **−7.80** | у нас VERIFY 10/cut_y 150 → взять стоковые |
| `input_shaper X` | **52.4** MZV | у нас 50 — обновить |
| `input_shaper Y` | **45.4** MZV | у нас 23.6 — обновить! |
| `heater_bed` PID | 18.578/0.152/298.489, max_power 0.5 | ✓ уже совпадает |
| bed mesh | 11×11, 5..255, bicubic | ✓ совпадает по сетке |

Вентиляторы при старте: M106 S127 (part fan 50%), M106 P2 S255 (aux на максимум
при чистке) — поверх их floor-ов (fan0_min 25, fan2_min 100).

## TODO в ваниле из этого playbook (приоритет)

1. **START_PRINT заменить на стоковый флоу** (LOAD=default вместо adaptive
   каждый раз; опция адаптива — флагом), сохранить нашу чистку.
2. **box.cfg: cut_pos_x=−7.8** (+ убрать VERIFY у cut), проверить остальное
   через CALIBRATE_CUT_POS на ваниле.
3. **Шейперы 52.4/45.4** в printer.cfg.
4. **CFS-фоновые команды**: на ваниле box-модуль сам делает поллинг — сверить
   интервал (4 c) и состав с GET_BOX_STATE.
5. **Сервисная зона**: сток ездит за Y=260 свободно (у нас motion_limits
   от Джейкоба режет Y>296.5 — совпадает, но проверить обтир Y265.5/X30..230
   не ограничивается лимитами чистки).
