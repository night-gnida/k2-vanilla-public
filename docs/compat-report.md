# Отчёт статического аудита совместимости (k2-vanilla)

Аудитор: `scripts/audit_compat.py` — AST-анализ вендоренных модулей против
деревьев хостов. Колонки: **stock** (форк из прошивки V1.1.6.7,
`rootfs_ext/usr/share/klipper/klippy`) и **v013** (klipper3d v0.13.0).

## Методика
1. Для каждого `files/*.py`: цели `lookup_object()`, вызовы методов на
   привязанных объектах, кросс-импорты, gcode-команды, опции конфига.
2. Для каждого хоста: наличие extras-модулей, методы классов ядра и extras,
   зарегистрированные команды, литералы `config.get*`.
3. Защищённые вызовы (hasattr-обёртки, lookup с default, try-импорты)
   помечаются отдельно и не считаются ошибками (список ручной верификации —
   `GUARDED_CALLS` в скрипте).

## Итог по v0.13 (целевой хост)
- **Все критичные расхождения устранены** (см. «Исправлено»).
- Единственный оставшийся пункт: `power_loss_recovery.py` → `z_align`
  (8 вызовов) — модуль **осознанно отключён** на базе: его восстановление
  завязано на dual-z хореографию z_align, камерный нагреватель (M141) и
  chamber_exhaust_fans — всё это Plus-only. Возвращать PLR будем отдельным
  портом под одиночный Z.
- Акселерометр lis2dw деградирует честно (предупреждение в лог): прошивка
  GD32 (сборка 2024-12) не знает новых сигнатур config/query_lis2dw.
  Резонансные тесты станут доступны после обновления прошивки MCU.

## Исправлено по результатам аудита
| Находка | Файл | Фикс |
|---|---|---|
| `has_active_homing_session`/`is_homing_abort_in_progress` (kalico homing API) в get_status | force_stop_homing.py | hasattr-деградация; force-stop через web request даёт явное сообщение |
| `request_homing_abort` | force_stop_homing.py | hasattr-гвард + сообщение «используйте аварийный стоп» |
| `has_active_homing_session`/`is_homing_session_aborted`/`is_homing_abort_in_progress` в _get_homing_session_state | motor_control.py | возврат нейтрального состояния на апстриме |
| `toolhead.Coord` (kalico класс) в _set_cut_x_limit | box.py, motor_control.py | запись в `kin.axes_min[0]` списком на апстриме |
| `[fan]/[fan_generic] min_power` (нет в v0.13) | printer.cfg | `off_below` |
| `[temperature_sensor mcu_temp/nozzle_mcu_temp]` temperature_mcu | printer.cfg | удалены (GD32 fw не отдаёт температуру чипа апстриму) |
| `endstop_pin: probe:` → чип регистрируется поздно | printer.cfg + prtouch.py | `prtouch:z_virtual_endstop`, безусловный register_chip |
| `[printer]` до include'ов | printer.cfg | секция перенесена в конец |
| Config CRC dance / таймауты MCU | install.sh | TRSYNC_TIMEOUT 0.05, serialhdl бюджет 300с/15с |

## Известные ограничения аудитора
- Опции конфига, читаемые с **динамическими ключами** (конкатенация строк:
  `shaper_freq_%s`, `screw%d`, параметры tmc), статическим разбором не
  видны — остаточные строки «config[...]» в отчёте носят справочный
  характер. Авторитетная проверка конфига — `check_unused` живого klippy,
  который наш пакет уже прошёл целиком.
- Связывание переменных с lookup_object — эвристика (присваивание в той же
  функции/атрибутом); сложные случаи могут давать шум в обе стороны.

## Запуск
```bash
python scripts/audit_compat.py \
  --host v013=toolchain/klipper-0.13.0/klippy \
  --host stock=../Принтер\ K2\ base\ combo/firmware/extracted/rootfs_ext/usr/share/klipper/klippy
```
