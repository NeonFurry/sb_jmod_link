--[[--------------------------------------------------------------------
	SB <-> JMod Link :: EZ-Battery Deposition (v5.0)
	Перенос заряда из JMod-батареи в энергетические приборы.

	Сверено по исходникам JMod (https://github.com/Jackarunda/gmod):
	  - батарея ent_jack_gmod_ezbattery НЕ имеет GetElectricity.
	    Она наследуется от ent_jack_gmod_ezresource и хранит заряд
	    в NetworkVar "Resource": ENT:GetResource()/SetResource(n),
	    MaxResource, EZsupplies == "power" (JMod.EZ_RESOURCE_TYPES.POWER).
	  - у машин (генераторы, power bank, турели) есть
	    ENT:TryLoadResource(type, amount) — штатный приёмник энергии.
	    Он возвращает ПРИНЯТОЕ количество и ограничен ёмкостью
	    MaxElectricity, а также не чаще одного раза в секунду
	    (внутри выставляет NextRefillTime = Time + 1).
	  - прямой SetElectricity возможен, но обходит эту логику,
	    поэтому для JMod-цели используется TryLoadResource.

	Для SB/CAF-приборов заряд идёт дельтой через RD.SupplyResource
	(SetResourceAmount в RD3 не существует), а принятое количество
	считается по фактическому изменению значения.

	Режимы:
	  1) Контактный перелив (sbjmod_ezbat_touch, по умолчанию ВЫКЛ):
	     заряженная батарея рядом с прибором отдаёт sbjmod_ezbat_rate
	     единиц в секунду, пока не опустеет.
	  2) Разовый слив по E (sbjmod_ezbat_range): навёлся на батарею,
	     нажал E — заряд ушёл в ближайший прибор.
--------------------------------------------------------------------]]

if not SERVER then return end

SB_JMOD = SB_JMOD or {}

local VERSION = "5.0"
local BATTERY_CLASS = "ent_jack_gmod_ezbattery"
local POWER = "power" -- JMod.EZ_RESOURCE_TYPES.POWER

local cvTouch = CreateConVar("sbjmod_ezbat_touch", "0",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Контактный перелив заряда от EZ-батареи (1/0). По умолчанию выключен")
local cvDist = CreateConVar("sbjmod_ezbat_touchdist", "50",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Дистанция касания для контактного перелива")
local cvRate = CreateConVar("sbjmod_ezbat_rate", "25",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Скорость контактного перелива, ед/сек")
local cvRange = CreateConVar("sbjmod_ezbat_range", "150",
	bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Радиус поиска прибора для разового слива по E")

local function IsBattery(e)
	if not IsValid(e) then return false end
	local cls = string.lower(e:GetClass() or "")

	-- современный JMod
	if cls == BATTERY_CLASS then return true end

	-- JMod Legacy: ent_jack_turretbattery — предмет с полем BatteryCharge
	if string.find(cls, "battery", 1, true) then
		if e.EZsupplies == "power" then return true end
		if tonumber(e.BatteryCharge) ~= nil then return true end
		if isfunction(SB_JMOD.IsLegacyJModClass) and SB_JMOD.IsLegacyJModClass(cls) then
			if isfunction(e.GetResource) or tonumber(e.Resource) then return true end
		end
	end
	return false
end

local function GetBatteryCharge(e)
	-- legacy-батарея: обычное поле
	if tonumber(e.BatteryCharge) ~= nil then return tonumber(e.BatteryCharge) end
	if isfunction(e.GetResource) then
		local ok, v = pcall(e.GetResource, e)
		if ok and tonumber(v) then return tonumber(v) end
	end
	return tonumber(e.Resource) or 0
end

local function SetBatteryCharge(e, v)
	v = math.max(0, math.floor(v + 0.5))
	if tonumber(e.BatteryCharge) ~= nil then
		local max = tonumber(e.MaxCharge) or tonumber(e.BatteryMaxCharge)
		e.BatteryCharge = max and math.min(v, max) or v
		if e.HasBattery and e.Dead ~= nil then
			e.Dead = false
			if isfunction(e.SetCollisionGroup) then
				pcall(e.SetCollisionGroup, e, COLLISION_GROUP_NONE)
			end
		end
	elseif isfunction(e.SetResource) then
		pcall(e.SetResource, e, v)
	else
		e.Resource = v
	end
end

local function GetRD()
	if RD and isfunction(RD.SupplyResource) then return RD end
	if CAF and isfunction(CAF.GetAddon) then
		local ok, rd = pcall(CAF.GetAddon, "Resource Distribution")
		if ok and rd and isfunction(rd.SupplyResource) then return rd end
	end
	return nil
end

--- Влить до amount единиц энергии в прибор. Возвращает принятое.
local function AddEnergy(e, kind, amount)
	if amount <= 0 then return 0 end

	-- JMod Legacy: заряд — обычное поле BatteryCharge
	if kind == "jmod" or kind == "both" then
		if tonumber(e.BatteryCharge) ~= nil then
			local max = tonumber(e.MaxCharge) or tonumber(e.BatteryMaxCharge) or amount
			local cur = tonumber(e.BatteryCharge) or 0
			local give = math.min(amount, max - cur)
			if give <= 0 then return 0 end
			e.BatteryCharge = cur + give
			if e.HasBattery and e.Dead ~= nil then
				e.Dead = false
				if isfunction(e.SetCollisionGroup) then
					pcall(e.SetCollisionGroup, e, COLLISION_GROUP_NONE)
				end
			end
			-- sbjmod_legacy_power_flags: поднять HasBattery/HasBatteryOne+Two
			if isfunction(SB_JMOD.LegacySyncPowerFlags) then
				SB_JMOD.LegacySyncPowerFlags(e)
			end
			return give
		end
	end

	-- JMod-машина: штатный приёмник, сам режет по ёмкости и частоте
	if (kind == "jmod" or kind == "both") and isfunction(e.TryLoadResource) then
		local ok, accepted = pcall(e.TryLoadResource, e, POWER, amount)
		if ok and tonumber(accepted) then
			return math.max(0, math.min(tonumber(accepted), amount))
		end
		return 0
	end

	-- SB/CAF-прибор: дельта через RD, считаем по факту изменения
	local rd = GetRD()
	if rd then
		local before
		local okB, v = pcall(rd.GetResourceAmount, e, "energy", false)
		if okB and isnumber(v) then before = v end

		pcall(rd.SupplyResource, e, "energy", amount)

		if before then
			local okA, v2 = pcall(rd.GetResourceAmount, e, "energy", false)
			if okA and isnumber(v2) then return math.max(0, v2 - before) end
		end
		return amount
	end

	-- последняя надежда: методы самой сущности
	if isfunction(e.SupplyResource) then
		pcall(e.SupplyResource, e, "energy", amount)
		return amount
	end
	return 0
end

local function Sparks(pos)
	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("GlassImpact", ed)
end

local function KillBattery(bat)
	Sparks(bat:GetPos())
	bat:EmitSound("ambient/energy/zap" .. math.random(1, 3) .. ".wav", 70)
	bat:Remove()
end

--- Ближайший прибор, который умеет принимать энергию.
local function FindDevice(pos, radius, exclude)
	local best, bestKind, bestD = nil, nil, nil
	for _, e in ipairs(ents.FindInSphere(pos, math.max(radius, 1))) do
		if IsValid(e) and e ~= exclude and not IsBattery(e) and not e:IsPlayer() then
			local kind = SB_JMOD.Identify and SB_JMOD.Identify(e) or nil
			if kind then
				local d = e:GetPos():Distance(pos)
				if (not bestD) or (d < bestD) then
					best, bestKind, bestD = e, kind, d
				end
			end
		end
	end
	return best, bestKind
end

--- Все батареи на карте: класс современный + legacy-варианты.
--- ents.FindByClass знает только точное имя, поэтому перебираем всё.
local function CollectBatteries()
	local out = {}
	for _, e in ipairs(ents.GetAll()) do
		if IsBattery(e) then out[#out + 1] = e end
	end
	return out
end

-- КОНТАКТНЫЙ ПЕРЕЛИВ: раз в секунду ищем заряженные батареи рядом с приборами
timer.Create("SBJMOD_EZBAT_Touch", 1, 0, function()
	if not cvTouch:GetBool() then return end
	local rate = math.max(1, cvRate:GetInt())
	local dist = math.max(0, cvDist:GetFloat())

	for _, bat in ipairs(CollectBatteries()) do
		local charge = GetBatteryCharge(bat)
		if charge > 0 then
			local dev, kind = FindDevice(bat:GetPos(), dist, bat)
			if dev then
				local give = AddEnergy(dev, kind, math.min(rate, charge))
				if give > 0 then
					charge = charge - give
					if charge <= 0.5 then
						KillBattery(bat)
					else
						SetBatteryCharge(bat, charge)
					end
				end
			end
		end
	end
end)

-- РАЗОВЫЙ СЛИВ ПО E: навёлся на батарею, нажал E — заряд ушёл целиком
hook.Add("PlayerUse", "SBJMOD_EZBAT_Dump", function(ply, e)
	if not IsValid(ply) or not IsBattery(e) then return end

	local charge = GetBatteryCharge(e)
	if not charge or charge <= 0 then return end -- пустая: обычный подбор

	local dev, kind = FindDevice(e:GetPos(), cvRange:GetFloat(), e)
	if not dev then return end -- рядом нет прибора — обычный подбор

	local give = AddEnergy(dev, kind, charge)
	if give <= 0 then
		ply:ChatPrint("[SBJMOD] " .. dev:GetClass() .. " сейчас не принимает энергию.")
		return false
	end

	local rest = charge - give
	if rest <= 0.5 then
		KillBattery(e)
		ply:ChatPrint(("[SBJMOD] Вставлено %d ед. в %s. Батарея израсходована."):format(
			math.floor(give), dev:GetClass()))
	else
		SetBatteryCharge(e, rest)
		ply:ChatPrint(("[SBJMOD] Влито %d ед. в %s, в батарее осталось %d."):format(
			math.floor(give), dev:GetClass(), math.floor(rest)))
	end
	return false -- не даём батарее улететь в инвентарь вместе с переливом
end)

if not SB_JMOD.HotReloading then
	print("[SBJMOD] EZ-Battery module v" .. VERSION .. " загружен (выключен: sbjmod_ezbat_touch 1)")
end
