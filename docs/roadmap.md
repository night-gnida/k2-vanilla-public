# Роадмап k2-vanilla (утверждён 2026-09-08)

Конечная точка: работающий K2 base (F021) на ванильном Klipper с набором
улучшений, отсутствующих в стоке. Режим работы с железом — «гибрид»:
по SSH без вопросов — статус/деплой/рестарт klipper; движение, нагрев,
старт печати — только по явному ОК.

## Этап 1 — первая полная печать (в работе)

1.1 Конфиги по playbook TODO: шейперы 52.4/45.4 MZV; box cut_pos_x −7.8;
    START_PRINT грузит mesh LOAD="default" (ADAPTIVE — флаг, по умолчанию
    выкл). — ГОТОВО (локально).
1.2 Статический аудит: сервисная зона (Y265.5/X30..230/Z−0.31 в пределах
    позиционных лимитов; motion_limits.py режет только velocity);
    box.py поллинг 1 c/5 c — паритет со стоком есть; найден и исправлен
    хардкод Y350/X300 в filament_retry_motion (Plus-координаты на базе F021);
    M106 P0/P2 ок; fan-минимумы стока (fan0_min 25, fan2_min 100) —
    отложено в Этап 3. — ГОТОВО.
1.3 Деплой + железный цикл — В РАБОТЕ (2026-09-09): установка восстановлена
    после сток-сброса (install.sh теперь работает без Entware/wget, ставит
    из локального тарбола, верифицирует конфиги — UDISK FTL stale pages);
    меш default снят (11×11, ≈ сток ±6 мкм) и перенесён в config/mesh.cfg
    (SAVE_CONFIG не пишет — известный блокер, обход); шейперы 52.4/45.4,
    cut_pos_x −7.8, arcs 1.0, taskset — применены и верифицированы;
    NOZZLE_CLEAN-обёртка с подъёмом Z5; START_PRINT в сток-порядке.
    Установлен Phaetus DXC-2 (5:1 на стоковом E-серво): retract_velocity 60,
    rotation_distance — калибровать перед печатью. Осталось: калибровка RD,
    сверка защиты моторов (0.3 vs сток ID39), NOZZLE_CLEAN траектория,
    Benchy PETG (Orca «Creality K2»). Журнал: docs/stage1-log.md.
1.4 README-статус переписан; из git убраны пустой docs/capture.tar.gz и
    scripts/__pycache__/*.pyc. — ГОТОВО.

Критерий: модель (Benchy) напечатана до конца.

## Этап 2 — паритет со стоком

- CALIBRATE_CUT_POS на ваниле (обязателен до первой смены филамента),
  живые BOX_LOAD/UNLOAD/CUT, runout.
- Подтвердить VERIFY-координаты box.cfg (clean_pad edges 286.5/296.5,
  wastebin 115/294) на живой поездке.
- PAUSE/RESUME/CANCEL с CFS, toolchange, watchdog, откат install.sh revert.

## Этап 3 — улучшения (порядок по ценности/риску; состав каждого —
отдельным мини-планом)

1. Быстрый старт: adaptive mesh + line purge (KAMP-стиль) как опциональный
   флоу (порт kalico-модуля line_purge.py); heat-soak-логика стока
   (bed_steady [50,70,80,100] / bed_steady_time [360,360,480,480]);
   сокращение времени до старта.
2. Надёжность: порт PLR под single-Z (vendored power_loss_recovery.py
   отключён из-за Plus-зависимостей z_align); диагностика 485-шины;
   runout/pause/resume вылизать; BELT_TENSION — порт belt_mdl.py у Джейкоба
   (у нас не вендорен); MOTOR_CALIBRATE уже есть в vendored motor_control.py.
3. Мониторинг и UI: камера сопла в Fluidd (WebRTC, стоковый сервис на :8000);
   timelapse (подход Джейкоба: TIMELAPSE_TAKE_FRAME в START_PRINT +
   moonraker-timelapse); HelixScreen на родной тачскрин (протестирован на
   K2-семействе; CFS-поддержка у него сырая — проверять); спул-менеджмент:
   RFID-ридер уже в box.py (внутренний, RS-485), спул на слот как у Джейкоба
   (box.spool_N vars + Spoolman), Fluidd-виджет «Filament Box» — только если
   стоковый Fluidd потянет кастомные панели (у нас он старый, не как в
   стеке Джейкоба).
4. Скорость/качество: SHAPER_CALIBRATE на месте — корень несовместимости
   lis2dw найден (2026-09-08): сток GD32 собран под СТАРЫЕ подписи команд
   (config_lis2dw oid/spi_oid; query_lis2dw oid/clock/rest_ticks;
   стрим lis2dw_data), а апстрим v0.13 шлёт новые (bus_oid/bus_oid_type,
   без clock) — MCU не парсит → protocol error. План: адаптировать
   lis2dw из форка Креалити (GPL, 265 строк; референс:
   toolchain/reference/lis2dw_creality_fork.py, локально) под хост v0.13 —
   command-сигнатуры оставить старые, обвязку (motion_report, bus)
   подогнать. Без реверса MCU и без перепрошивки. Запасной путь — внешний
   акселерометр; PA под DXC-2 (5:1 редуктор — после калибровки
   rotation_distance; типичный диапазон директ-подачи 0.03–0.06);
   per-filament PA; профили скорости (аналог Qmode:
   сток qmode max_accel 2500).

Отложенная полировка (из Этапа 1.2): fan-минимумы стока в M106-макро
(P0 ≥ 25/255, P2 ≥ 100/255 при S>0).
