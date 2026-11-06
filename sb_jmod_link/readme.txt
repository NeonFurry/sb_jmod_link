SB <-> JMod Link v7.0
=====================
Двусторонняя перекачка энергии: Spacebuild (energy) <-> JMod (Electricity),
с поддержкой CAF / Resource Distribution (Spacebuild 3, Life Support).

НОВОЕ В v7.0 — Auto Link Tool:
Штатный Auto Link Tool из RD3 теперь понимает JMod-устройства:
- ЛКМ по ноде RD -> все JMod-банки в радиусе ноды подключаются к нашей
  системе связей (RD-устройства при этом линкуются как обычно);
- ЛКМ по JMod-банку -> выбор цели 1, следующий клик по ноде/устройству
  создаёт связь;
- ПКМ по JMod-банку -> снимает наши связи с ним.
Скорость перекачки для Auto Link: консольная переменная sbjmod_defrate
(по умолчанию 50 ед/сек, применяется только к новым связям).

УСТАНОВКА:
1. Полностью удалите garrysmod/addons/sb_jmod_link (и старые версии).
2. Распакуйте архив: garrysmod/addons/sb_jmod_link/...
3. Подпишите Spacebuild 3 (Workshop 693838486) — в нём CAF и Life Support.
4. Полный перезапуск GMod. Карты должны начинаться с sb_ (CAF активен
   только на таких картах).

СТРУКТУРА:
  lua/autorun/sb_jmod_link.lua          - ядро (тул, связи, сеть)
  lua/sb_jmod/transfer.lua              - насос (сервер)
  lua/sb_jmod/rope.lua                  - физический трос (сервер)
  lua/sb_jmod/caf.lua                   - мост к RD3 (сервер)
  lua/sb_jmod/autolink.lua              - патч Auto Link Tool (сервер)
  lua/weapons/gmod_tool/stools/sb_jmodlink.lua - тул (имя = TOOL.Mode!)

ПРОВЕРКА ЗАГРУЗКИ (консоль):
  sb_jmod_dump           - список связей с типами и ресурсами
  lua_run_cl print(SB_JMOD and SB_JMOD.Version or "ЯДРА НЕТ")

ПЕРЕЗАГРУЗКА: sbjmod_reload (сервер) -> sbjmod_reload_cl (клиент)
-> тулган в руки заново.

КОМАНДЫ:
  sbjmod_select          - выбрать объект под прицелом
  sbjmod_link            - связать выбранное с объектом под прицелом
  sbjmod_reset           - сбросить выбор
  sb_jmod_dump           - список связей (админ)

ПРИМЕЧАНИЯ:
- Направление перекачки определяется автоматически каждую секунду:
  энергия течёт оттуда, где её больше.
- Ресурс для связей с CAF - energy (совместное обоих систем).
- Если два CAF-устройства уже в одной RD-сети - наш тул не нужен,
  используйте штатный линк RD.
