--[[
	SB <-> JMod Link: EZ-Battery Deposition v3.0
	Поведение v1: E по батарее (ent_jack_gmod_ezbattery) рядом с устройством —
	заряд целиком переливается в устройство; пустая батарея исчезает с искрами.
	Если ёмкость устройства не влезла — батарея остаётся с остатком заряда.

	Совместимость — та же система, что и у всего мода:
	используется SB_JMOD.Identify (JMod / SB / CAF-RD).
	Ядро sb_jmod_link.lua менять не нужно: модуль самодостаточен.
]]

SB_JMOD = SB_JMOD or {}

local BATTERY_CLASS = "ent_jack_gmod_ezbattery"
local RESOURCE = "energy"

local cvarRange = CreateConVar("sbjmod_ezbat_range", "150", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
	"Радиус поиска устройства, в которое можно влить заряд батареи")

--------------------------------------------------------------------
-- Определение типа устройства (свой дубль на случай,
-- если ядро SB_JMOD ещё не успело загрузиться)
--------------------------------------------------------------------
local CAF_PREFIXES = { "storage_", "generator_", "other_", "residue_", "reactor_" }

local function IdentifyType(e)
	if not IsValid(e) then return nil end
	if isfunction(SB_JMOD.Identify) then
		local ok, t = pcall(SB_JMOD.Identify, e)
		if ok and t then return t end
	end

	local isJMod = isfunction(e.GetElectricity) and isfunction(e.SetElectricity)
	local isSB = isfunction(e.GetResourceAmount) and isfunction(e.SetResourceAmount)
	if isJMod then return "jmod" end
	if isSB then return "sb" end

	local okRD, isCAF = pcall(function()
		if RD and isfunction(RD.GetEntityTable) then
			return RD.GetEntityTable(e) ~= nil
		end
		return false
	end)
	if okRD and isCAF then return "caf" end

	local cls = e:GetClass()
	for _, pref in ipairs(CAF_PREFIXES) do
		if string.find(cls, pref, 1, true) then return "caf" end
	end
	return nil
end

--------------------------------------------------------------------
-- Доступ к заряду устройства (обёрнуто в pcall — ничего не роняет сервер)
--------------------------------------------------------------------
local function GetDevice(e)
	local typ = IdentifyType(e)
	if not typ then return nil end

	if typ == "jmod" or typ == "both" then
		local cap = e.MaxElectricity
		if not isnumber(cap) then
			local ok, v = pcall(function()
				return isfunction(e.GetMaxElectricity) and e:GetMaxElectricity() or nil
			end)
			if ok and isnumber(v) then cap = v end
		end
		cap = cap or math.huge
		return {
			cur = function()
				local ok, v = pcall(e.GetElectricity, e)
				return (ok and isnumber(v)) and v or 0
			end,
			add = function(amt)
				local ok, v = pcall(e.GetElectricity, e)
				if ok and isnumber(v) then pcall(e.SetElectricity, e, v + amt) end
			end,
			cap = cap,
			name = "JMod: " .. e:GetClass(),
		}
	end

	if typ == "sb" then
		return {
			cur = function()
				local ok, v = pcall(e.GetResourceAmount, e, RESOURCE)
				return (ok and isnumber(v)) and v or 0
			end,
			add = function(amt)
				local ok, v = pcall(e.GetResourceAmount, e, RESOURCE)
				if ok and isnumber(v) then pcall(e.SetResourceAmount, e, RESOURCE, v + amt) end
			end,
			cap = math.huge, -- у легаси-SB ёмкость наружу не выдаётся
			name = "SB: " .. e:GetClass(),
		}
	end

	if typ == "caf" then
		local cap = math.huge
		local okC, v = pcall(function()
			if RD and isfunction(RD.GetNetworkCapacity) then
				return RD.GetNetworkCapacity(e, RESOURCE)
			end
			return nil
		end)
		if okC and isnumber(v) and v > 0 then cap = v end
		return {
			cur = function()
				if not (RD and isfunction(RD.GetResourceAmount)) then return 0 end
				local ok, val = pcall(RD.GetResourceAmount, e, RESOURCE)
				return (ok and isnumber(val)) and val or 0
			end,
			add = function(amt)
				if not (RD and isfunction(RD.GetResourceAmount)) then return end
				local ok, val = pcall(RD.GetResourceAmount, e, RESOURCE)
				if ok and isnumber(val) and isfunction(RD.SetResourceAmount) then
					pcall(RD.SetResourceAmount, e, RESOURCE, val + amt)
				end
			end,
			cap = cap,
			name = "CAF: " .. e:GetClass(),
		}
	end

	return nil
end

--------------------------------------------------------------------
-- Заряд батареи
--------------------------------------------------------------------
local function GetBatteryAmount(bat)
	local ok, v = pcall(bat.GetElectricity, bat)
	return (ok and isnumber(v)) and v or 0
end

local function SetBatteryAmount(bat, v)
	pcall(bat.SetElectricity, bat, v)
end

--------------------------------------------------------------------
-- Поиск ближайшего совместимого устройства
--------------------------------------------------------------------
local function FindDevice(pos)
	local best, bestDist
	for _, e in ipairs(ents.FindInSphere(pos, cvarRange:GetInt())) do
		if IsValid(e) and e:GetClass() ~= BATTERY_CLASS then
			if IdentifyType(e) then
				local dist = e:GetPos():Distance(pos)
				if not bestDist or dist < bestDist then
					best, bestDist = e, dist
				end
			end
		end
	end
	return best
end

local function Sparks(pos)
	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("Sparks", ed)
	sound.Play("ambient/energy/zap1.wav", pos, 70, 100, 0.7)
end

--------------------------------------------------------------------
-- Основной обработчик: E по батарее = влить заряд
--------------------------------------------------------------------
hook.Add("PlayerUse", "SBJMOD_EZBat_Pour", function(ply, ent)
	if not IsValid(ent) or ent:GetClass() ~= BATTERY_CLASS then return end

	local charge = GetBatteryAmount(ent)
	if charge <= 0 then return end -- пустая батарея: обычный подбор в инвентарь

	local dev = FindDevice(ent:GetPos())
	if not IsValid(dev) then return end -- устройства рядом нет — обычный подбор

	local info = GetDevice(dev)
	if not info then return end

	local cur = info.cur()
	local free = info.cap - cur
	if free <= 0 then
		ply:ChatPrint("[SBJMOD] Устройство уже заполнено: " .. info.name)
		return false -- блокируем случайный подбор: E здесь означает «вставить»
	end

	local amt = math.min(charge, free)
	info.add(amt)
	SetBatteryAmount(ent, charge - amt)
	Sparks(ent:GetPos())

	local left = charge - amt
	if left <= 0 then
		ply:ChatPrint("[SBJMOD] Влито " .. math.Round(amt) .. " ед. в " .. info.name .. ". Батарея исчерпана и исчезла.")
		ent:Remove()
	else
		ply:ChatPrint("[SBJMOD] Влито " .. math.Round(amt) .. " ед. в " .. info.name .. ". В батарее осталось " .. math.Round(left) .. " ед.")
	end

	return false -- заблокировать подбор батареи в инвентарь этим же нажатием
end)

print("[SBJMOD] EZ-Battery Deposition v3.0 загружен (влить заряд по E, пустая батарея исчезает)")
