--[[--------------------------------------------------------------------
	SB <-> JMod Link :: JMod Legacy compatibility (v1.0)

	«JMod Legacy» (Steam Workshop 2157935882) — это НЕ форк JMod, а
	авторская подборка старого контента (JIDS, OpSquads и т.п.) поверх
	современного JMod: в описании прямо сказано, что требуется сам JMod.
	Старые сущности используют префикс ent_jack_ (без «gmod»), например
	ent_jack_fgcartridge_energy, и в тот же период уже существовали
	ent_jack_gmod_ez*.

	Поэтому совместимость построена не на списке имён классов, а на
	признаках энергетики. Проверено по распакованным файлам аддона
	(Workshop 2157935882, 400 Lua-файлов):
	  - основная модель legacy — ОБЫЧНОЕ ПОЛЕ BatteryCharge у сущности,
	    ёмкость MaxCharge (турели) или BatteryMaxCharge (батарея,
	    терминал, aidcomm); методы ExternalCharge есть, но ведут себя
	    по-разному (батарея ставит полный заряд, терминал прибавляет amt);
	  - ent_jack_powernode — хаб, который раздаёт заряд зависимым
	    сущностям от генератора (fuel-based, поле Remaining);
	  - ent_jack_generator сам заряда не хранит;
	  - современный JMod: GetElectricity/SetElectricity у машин,
	    TryLoadResource("power"), ресурс power / поле Resource у батарей.

	Совместимость = сущность с префиксом ent_jack_ и любым признаком
	энергии считается JMod-устройством («jmod»), поэтому её видит тул,
	насос и HUD.

	Отключается конваром sbjmod_legacy_mode 0 — на случай ложных
	срабатываний на нестандартном контенте.

	Ограничение: топливо legacy-генератора (Remaining) в энергию не
	переводится — мост работает с зарядом конкретных сущностей.
--------------------------------------------------------------------]]

if not SERVER then return end

SB_JMOD = SB_JMOD or {}

local cvLegacy = CreateConVar("sbjmod_legacy_mode", "1",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Распознавать сущности JMod Legacy (префикс ent_jack_) как JMod-энергию (0/1)")

-- Обход механики вставки батарей: если включено, зарядка сама поднимает
-- флаги HasBattery / HasBatteryOne+Two, без которых турели не запускаются
-- (turret_base:StartUp -> 905-906, tesla:Engage -> 137). По умолчанию
-- выключено, потому что это меняет баланс мода.
local cvFlags = CreateConVar("sbjmod_legacy_power_flags", "0",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Поднимать флаги HasBattery/HasBatteryOne+Two у Legacy-устройств при зарядке (0/1)")

--- Префикс legacy-контента: ent_jack_ (в него же входит ent_jack_gmod_)
function SB_JMOD.IsLegacyJModClass(cls)
	if not isstring(cls) then return false end
	return string.sub(string.lower(cls), 1, 9) == "ent_jack_"
end

--- Есть ли у сущности хоть один признак электричества JMod.
--- SB_JMOD.LegacyPowerSignal используется в transfer.lua и EZ-батарее.
function SB_JMOD.LegacyPowerSignal(e)
	if not IsValid(e) then return false end

	-- Главный признак legacy: обычное поле заряда
	if tonumber(e.BatteryCharge) ~= nil then return true end

	if isfunction(e.GetElectricity) then return true end
	if e.EZsupplies == "power" then return true end
	if tonumber(e.MaxElectricity) then return true end

	-- Старый путь: ENT:GetEZsupplies(typ) возвращает число заряда
	if isfunction(e.GetEZsupplies) then
		local ok, v = pcall(e.GetEZsupplies, e, "power")
		if ok and tonumber(v) then return true end
	end

	return false
end

--- Поднять флаги «батарея вставлена». Вызывается при записи заряда,
--- если включён sbjmod_legacy_power_flags.
--- Флаги и DT повторяют поведение RefillPower:
---   turret_base: HasBattery + SetDTBool(1)  (init.lua:949-952)
---   teslа:       HasBatteryOne/Two + SetDTBool(1/2) (init.lua:163-173)
---   процент:     SetDTInt(2, charge/max*100)
--- Возвращает true, если что-то поменялось.
function SB_JMOD.LegacySyncPowerFlags(e)
	if not cvFlags:GetBool() then return false end
	if not IsValid(e) then return false end
	if tonumber(e.BatteryCharge) == nil then return false end

	local changed = false

	if e.HasBattery ~= nil then
		if not e.HasBattery then changed = true end
		e.HasBattery = true
	end
	if e.HasBatteryOne ~= nil then
		if not e.HasBatteryOne then changed = true end
		e.HasBatteryOne = true
	end
	if e.HasBatteryTwo ~= nil then
		if not e.HasBatteryTwo then changed = true end
		e.HasBatteryTwo = true
	end
	if e.Dead ~= nil and e.Dead then
		e.Dead = false
		changed = true
		if isfunction(e.SetCollisionGroup) then
			pcall(e.SetCollisionGroup, e, COLLISION_GROUP_NONE)
		end
	end

	if isfunction(e.SetDTBool) then
		pcall(e.SetDTBool, e, 1, true)
		pcall(e.SetDTBool, e, 2, true)
	end

	local max = tonumber(e.MaxCharge) or tonumber(e.BatteryMaxCharge)
	if max and max > 0 and isfunction(e.SetDTInt) then
		pcall(e.SetDTInt, e, 2, math.Round((tonumber(e.BatteryCharge) / max) * 100))
	end

	return changed
end

if isfunction(SB_JMOD.AddIdentifier) then
	-- Приоритет 35: раньше core_methods (40), чтобы legacy-сущности с
	-- нестандартным набором методов всё равно попали в «jmod».
	SB_JMOD.AddIdentifier("jmod_legacy", 35, function(e)
		if not cvLegacy:GetBool() then return nil end
		if not SB_JMOD.IsLegacyJModClass(e:GetClass()) then return nil end
		if not SB_JMOD.LegacyPowerSignal(e) then return nil end
		return "jmod"
	end)
end

if not SB_JMOD.HotReloading then
	print("[SBJMOD] Модуль JMod Legacy v1.0 загружен: префикс ent_jack_ + признаки энергии")
end
