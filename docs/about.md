# k2-vanilla — ванильный Klipper 3D для Creality K2 без перепрошивки железа

**Что это.** Комплект, который заменяет форк Creality на **чистый
апстрим-klipper3d v0.13.0** на базе K2 (плата F021, стол 260×260) — при
полностью стоковом железе. Прошивки GD32 (главный MCU и nozzle-MCU) **не
перепрошиваются**, стоковый OpenWrt на T113-i, Moonraker и Fluidd остаются
на месте. Сток живёт в соседнем слоте и возвращается одной командой.

**Почему это ценно.**

- **Апстрим без сюрпризов** — обычный klipper3d: любые актуальные модули и
  гайды применимы напрямую, ничего «форк-специфичного».
- **Открытые драйверы K2 (GPL)** вместо проприетарных `.so`: `prtouch`
  (тензорезисторный щуп), `serial_485` (RS-485-шина), `motor_control`
  (closed-loop серво X/Y/E), `box` (CFS-комбо) и др. — читаемые, правимые,
  документированные.
- **Безопасная установка**: скопировал каталог → `sh install.sh`. Конфиги
  стока не трогаются (ваниль живёт в `config-vanilla/`), watchdog,
  авто-откат при неудачном старте, `install.sh revert` в любой момент.
- **Резонансное тестирование на стоковом lis2dw** — портирован шим под
  старый протокол nozzle-MCU: `SHAPER_CALIBRATE`/`TEST_RESONANCES` без
  какого-либо reflasha.
- **Живой серийный опыт, а не теория**: сенсорный хоуминг с настроенной
  stall-детекцией, реальная 11×11 сетка, playbook стартовой
  последовательности стока, задокументированные грабли (потери на 485-шине,
  NAND UDISK stale pages, самохалт GD32 по защите мотора) и их решения.
- **Roadmap**: adaptive mesh + KAMP-purge, собственный power-loss recovery
  для single-Z, BELT_TENSION, камера сопла, профили скорости.

Установка и детали — в [README.md](../README.md) / [README_RU.md](../README_RU.md);
реверс-заметки по протоколам — [research-notes.md](research-notes.md).

## 🤝 Как помочь развитию — нематериально

- ⭐ **Звезда репо** — простейшее, но реально влияет на видимость;
- 🧪 **Тесты на своём K2** — особенно K2C/K2 Combo (модуль CFS мало проверен)
  и K2 Plus; issues с логами `klippy-vanilla.log`;
- 👀 **Ревью драйверов** — сверка поведения со стоком; wire-захват
  RS-485-трафика золотой;
- 📝 **Вычитка/перевод** README и docs, посты-обзоры — проект ищет
  пользователей;
- 💡 Идеи в roadmap через issues.

## 💰 Материальная помощь

- **Bitcoin (BTC)**:
  `bc1q8u04xphssp6qs0mc5ssk45mlgl7q04mjd35yqp2vurgkwdgehchsw39ge0`

*Донаты идут на железо для тестов (модуль CFS K2C, сменные платы) и время
на отладку. Проект некоммерческий, GPL-3.*

---

## EN short version

**k2-vanilla** — stock-hardware Klipper 3D v0.13.0 (upstream, no forks) for
the Creality K2: stock GD32 MCU firmware stays, stock host OS stays,
one-command install with instant rollback. Ships open-source (GPL)
replacements for Creality's binary klippy modules: strain-gauge probe,
RS-485 closed-loop motors, CFS. Resonance calibration on the stock lis2dw
accelerometer. Tested on a live printer, not a theory.

★ Star / test / review — [github.com/night-gnida/k2-vanilla-public](https://github.com/night-gnida/k2-vanilla-public).
Tips: BTC `bc1q8u04xphssp6qs0mc5ssk45mlgl7q04mjd35yqp2vurgkwdgehchsw39ge0`
