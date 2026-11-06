
--[[---------------------------------------------------------------------------
	SB <-> JMod Link — EZ Battery Deposition v4.0
	Контактная передача заряда: ent_jack_gmod_ezbattery, приложенная к устройству
	(JMod / SB / CAF-RD), переливает в него заряд порциями.
	Когда батарея пуста — исчезает с искрами.
	Дополнительно: разовый «дамп» всего заряда по нажатию E (use) на батарею.
	Самодостаточный модуль: использует SB_JMOD.Identify из ядра, если оно
	загружено, иначе — собственный резервный определитель.
-----------------------------------------------------------------------------]]

local TOUCH_RATE_KEY = "sbjmod_ezbat_rate"    -- ед/сек контактного перелива
local TOUCH_DIST_KEY = "sbjmod_ezbat_touchdist" -- дистанция «касания»
local USE_DIST_KEY   = "sbjmod_ezbat_range"   -- радиус поиска для дампа по E
local TICK_INTERVAL  = 0.5                    -- период контактного тика

if SERVER then
	CreateConVar(TOUCH_RATE_KEY, "25", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "EZ battery contact transfer rate (units/sec)")
	CreateConVar("sbjmod_ezbat_touch", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Enable contact-based battery charging (1/0)")
	CreateConVar(TOUCH_DIST_KEY, "50", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Contact distance for battery charging")
	CreateConVar(USE_DIST_KEY, "150", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY), "Search radius for E-dump of EZ battery")

	----------------------------------------------------------------
	-- Резервный определитель (если ядро ещё не загрузилось)
	----------------------------------------------------------------
	local function Identify(e)
		if not IsValid(e) then return nil end
		if SB_JMOD and isfunction(SB_JMOD.Identify) then
			local ok, t = pcall(SB_JMOD.Identify, e)
			if ok and t then return t end
		end
		local isJMod = isfunction(e.GetElectricity) and isfunction(e.SetElectricity)
		local isSB = isfunction(e.GetResourceAmount) and isfunction(e.SetResourceAmount)
		if isJMod and isSB then return "both" end
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
		for _, pref in ipairs({ "storage_", "generator_", "other_", "residue_", "reactor_" }) do
			if string.find(cls, pref, 1, true) then return "caf" end
		end
		return nil
	end

	----------------------------------------------------------------
	-- Ёмкость и заряд устройства (по типам)
	----------------------------------------------------------------
	local function GetCharge(e, t)
		t = t or Identify(e)
		if not t then return nil, nil end
		if t == "jmod" or t == "both" then
			local ok, cur = pcall(e.GetElectricity, e)
			if ok and isnumber(cur) then
				local cap = tonumber(e.MaxElectricity) or 100
				return cur, cap
			end
		end
		if t == "sb" or t == "both" then
			local ok, cur = pcall(e.GetResourceAmount, e, "energy")
			if ok and isnumber(cur) then
				local cap = math.huge
				pcall(function() cap = e:GetNetworkCapacity and e:GetNetworkCapacity("energy") or math.huge end)
				return cur, cap
			end
		end
		if t == "caf" then
			if RD and isfunction(RD.GetResourceAmount) then
				local ok, cur = pcall(RD.GetResourceAmount, e, "energy")
				if ok and isnumber(cur) then
					local cap = math.huge
					pcall(function() cap = RD.GetNetworkCapacity(e, "energy") or math.huge end)
					return cur, cap
				end
			end
		end
		return nil, nil
	end

	local function AddCharge(e, amount, t)
		t = t or Identify(e)
		if not t or not isnumber(amount) or amount <= 0 then return 0 end
		if t == "jmod" or t == "both" then
			local ok = pcall(e.SetElectricity, e, (e.GetElectricity and e:GetElectricity() or 0) + amount)
			if ok then return amount end
			return 0
		end
		if t == "sb" or t == "both" then
			local ok = pcall(e.SetResourceAmount, e, "energy", (e.GetResourceAmount and e:GetResourceAmount("energy") or 0) + amount)
			if ok then return amount end
			return 0
		end
		if t == "caf" then
			if RD and isfunction(RD.SetResourceAmount) then
				local ok = pcall(RD.SetResourceAmount, e, "energy", (RD.GetResourceAmount and RD.GetResourceAmount(e, "energy") or 0) + amount)
				if ok then return amount end
			end
		end
		return 0
	end

	----------------------------------------------------------------
	-- Перелив из батареи в устройство; true — батарея опустела
	----------------------------------------------------------------
	local function TransferFromBattery(bat, e, maxTake)
		local charge, cap = GetCharge(e)
		if not charge then return false end
		local space = (cap == math.huge) and math.huge or (cap - charge)
		if space <= 0 then return false end
		local stored = bat:GetElectricity and bat:GetElectricity() or 0
		if stored <= 0 then
			return true -- пустая
		end
		local give = math.min(stored, space, maxTake or stored)
		local added = AddCharge(e, give)
		local left = stored - added
		if isfunction(bat.SetElectricity) then
			pcall(bat.SetElectricity, bat, left)
		else
			bat.Electricity = left
		end
		if left <= 0.01 then
			-- Батарея опустела — искры, звук, исчезновение
			local pos = bat:GetPos()
			local ed = EffectData()
			ed:SetOrigin(pos)
			util.Effect("GlassImpact", ed, true, true)
			sound.Play("ent_jack_gmod_ezbattery_discharge.mp3", pos, 70, 100, 1)
			if IsValid(bat) then bat:Remove() end
			print("[SBJMOD][EZBAT] Батарея опустела и исчезла в " .. e:GetClass())
			return true
		end
		return false
	end

	----------------------------------------------------------------
	-- Контактный перелив: таймер по всем батареям
	----------------------------------------------------------------
	timer.Create("SBJMOD_EZBAT_Contact", TICK_INTERVAL, 0, function()
		if GetConVar("sbjmod_ezbat_touch"):GetBool() == false then return end
		local rate = GetConVar(TOUCH_RATE_KEY):GetFloat() * TICK_INTERVAL
		local dist = GetConVar(TOUCH_DIST_KEY):GetFloat()
		for _, bat in ipairs(ents.FindByClass("ent_jack_gmod_ezbattery")) do
			if IsValid(bat) and isfunction(bat.GetElectricity) and (bat:GetElectricity() or 0) > 0 then
				local bpos = bat:GetPos()
				for _, e in ipairs(ents.FindInSphere(bpos, dist)) do
					if IsValid(e) and e ~= bat and Identify(e) then
						local empty = TransferFromBattery(bat, e, rate)
						if empty or not IsValid(bat) then break end
					end
				end
			end
		end
	end)

	----------------------------------------------------------------
	-- Разовый дамп по E (use) на батарее
	----------------------------------------------------------------
	hook.Add("PlayerUse", "SBJMOD_EZBAT_Use", function(ply, ent)
		if not IsValid(ent) or ent:GetClass() ~= "ent_jack_gmod_ezbattery" then return end
		local stored = ent:GetElectricity and ent:GetElectricity() or 0
		if stored <= 0 then return end -- пустую не блокируем — пусть подбирается

		local range = GetConVar(USE_DIST_KEY):GetFloat()
		local bpos = ent:GetPos()
		local best, bestDist
		for _, e in ipairs(ents.FindInSphere(bpos, range)) do
			if IsValid(e) and e ~= ent and Identify(e) then
				local d = e:GetPos():DistToSqr(bpos)
				if not bestDist or d < bestDist then
					best, bestDist = e, d
				end
			end
		end
		if not IsValid(best) then return end -- обычный подбор в инвентарь

		TransferFromBattery(ent, best) -- целиком
		if IsValid(ent) then
			ply:ChatPrint(string.format("[SBJMOD] Влито %.0f ед. в %s; осталось %.0f ед.", stored, best:GetClass(), ent:GetElectricity() or 0))
		else
			ply:ChatPrint(string.format("[SBJMOD] Влито %.0f ед. в %s; батарея опустела и исчезла.", stored, best:GetClass()))
		end
		return false -- блокируем подбор заряженной батареи
	end)

	print("[SBJMOD] EZ Battery Deposition v4.0 загружен (contact + use)")
end
