--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Transfer (v7.3)
	Поддержка: JMod, Spacebuild/SB, CAF + resource_node (RD-сеть).
	Роли устройств:
	  генератор   ("generator", "gen_", "powersource", "reactor")
	  потребитель (turret, sentry)
	  накопитель  (банки, батареи, resource_node)
	Правила сети:
	  генератор -> банк/потребитель : можно
	  банк <-> банк                 : равный делёж
	  потребитель -> кто угодно     : ЗАПРЕЩЕНО
	  банк -> генератор и генератор <-> генератор: ЗАПРЕЩЕНО
	Интервал: 0,1 секунды. Лог: sbjmod_transferlog 1
	Диагностика: sbjmod_test_energy (устройство под прицелом).
--------------------------------------------------------------------]]

local cvLog = CreateConVar("sbjmod_transferlog", "0", FCVAR_ARCHIVE,
	"Показывать перекачку энергии в консоли (0/1)")

-- resource_node (Resourcer SB3/CAF)? Узел сам не хранит заряд, а является
-- окном в RD-сеть, поэтому читаем/пишем ресурс через RD.
local function IsResNode(e)
	return string.find(string.lower(e:GetClass() or ""), "resource_node", 1, true) ~= nil
end

-- ======== РАСШИРЕНИЕ ЯДРА: resource_node ========
local OriginalIdentify = SB_JMOD.Identify
SB_JMOD.Identify = function(e)
	if not IsValid(e) then return nil end
	if IsResNode(e) then return "sbres" end
	local t = OriginalIdentify and OriginalIdentify(e) or nil
	if t then return t end
	return nil
end

SB_JMOD.IdentifyExt = function(e)
	if not IsValid(e) then return nil end
	return SB_JMOD.Identify(e)
end

-- Чтение заряда устройства: возвращает текущее значение и ёмкость
local function GetCharge(e, t)
	if t == "jmod" then
		local ok, cur = pcall(e.GetElectricity, e)
		if not ok or cur == nil then return nil end
		local max = tonumber(e.MaxElectricity) or 1000
		if max <= 0 then max = 1000 end
		return tonumber(cur) or 0, max

	elseif t == "sb" or t == "caf" or t == "sbres" then
		-- Через глобальный RD (Resource Distribution из SB3/CAF)
		if RD and isfunction(RD.GetResourceAmount) then
			local ok, cur = pcall(RD.GetResourceAmount, e, "energy")
			if ok and cur ~= nil then
				local cap = 10000
				if isfunction(e.GetNetworkCapacity) then
					local okc, c = pcall(e.GetNetworkCapacity, e, "energy")
					if okc and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
				end
				return tonumber(cur) or 0, cap
			end
		end
		-- Запасной вариант: методы на самой энтити
		local ok, cur = pcall(e.GetResourceAmount, e, "energy")
		if not ok or cur == nil then return nil end
		local cap = 10000
		if isfunction(e.GetNetworkCapacity) then
			local okc, c = pcall(e.GetNetworkCapacity, e, "energy")
			if okc and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
		end
		return tonumber(cur) or 0, cap
	end

	return nil
end

-- Запись заряда устройства
local function SetCharge(e, t, val)
	val = math.max(0, math.floor(val))
	if t == "jmod" then
		pcall(e.SetElectricity, e, val)
	elseif t == "sb" then
		pcall(e.SetResourceAmount, e, "energy", val)
	elseif t == "caf" or t == "sbres" then
		if RD and isfunction(RD.SetResourceAmount) then
			local ok, _ = pcall(RD.SetResourceAmount, e, "energy", val)
			if ok then return end
		end
		pcall(e.SetResourceAmount, e, "energy", val)
	end
end

-- Роль устройства: "gen", "cons" или "bank"
local function GetRole(e)
	local cls = string.lower(e:GetClass() or "")
	if string.find(cls, "turret", 1, true)
		or string.find(cls, "sentry", 1, true) then
		return "cons"
	end
	if string.find(cls, "generator", 1, true)
		or string.find(cls, "gen_", 1, true)
		or string.find(cls, "_gen", 1, true)
		or string.find(cls, "powersource", 1, true)
		or string.find(cls, "reactor", 1, true) then
		return "gen"
	end
	-- resource_node и всё прочее — накопители (банки, батареи)
	return "bank"
end

local function TransferLink(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end

	local ta = SB_JMOD.Identify and SB_JMOD.Identify(l.a) or nil
	local tb = SB_JMOD.Identify and SB_JMOD.Identify(l.b) or nil
	if not ta or not tb then return end

	local roleA = GetRole(l.a)
	local roleB = GetRole(l.b)

	if roleA == "gen" and roleB == "gen" then return end

	local allowAB = true
	local allowBA = true
	if roleA == "bank" and roleB == "gen" then
		allowAB = false
	elseif roleB == "bank" and roleA == "gen" then
		allowBA = false
	elseif roleA == "cons" then
		allowAB = false
	elseif roleB == "cons" then
		allowBA = false
	end

	local curA, capA = GetCharge(l.a, ta)
	local curB, capB = GetCharge(l.b, tb)
	if not curA or not curB or not capA or not capB then return end
	if capA <= 0 or capB <= 0 then return end

	local total = curA + curB
	if total <= 0 then return end

	local wantA = math.min(math.floor(total / 2), capA)
	local wantB = math.min(total - wantA, capB)
	if wantB < total - wantA then
		wantA = math.min(total - wantB, capA)
	elseif wantA < total - wantB then
		wantB = math.min(total - wantA, capB)
	end

	local function DoMove(src, srcT, dst, dstT, sCur, sWant, dCur, dWant, srcEnt, dstEnt)
		local surplus = sCur - sWant
		local deficit = dWant - dCur
		if surplus <= 0 or deficit <= 0 then return 0 end
		local give = math.min(surplus, deficit)
		if give <= 0 then return 0 end

		SetCharge(src, srcT, sCur - give)
		SetCharge(dst, dstT, dCur + give)

		if cvLog:GetBool() then
			print(("[SBJMOD] %s (%s) -> %s (%s): +%d"):format(
				srcEnt:GetClass(), srcEnt == l.a and roleA or roleB,
				dstEnt:GetClass(), dstEnt == l.a and roleA or roleB, give))
		end
		return give
	end

	if allowAB and curA > wantA then
		DoMove(l.a, ta, l.b, tb, curA, wantA, curB, wantB, l.a, l.b)
	end
	if allowBA and curB > wantB then
		DoMove(l.b, tb, l.a, ta, curB, wantB, curA, wantA, l.b, l.a)
	end
end

timer.Create("SBJMOD_Transfer", 0.1, 0, function()
	if not SB_JMOD.Links or #SB_JMOD.Links == 0 then return end
	for _, l in ipairs(SB_JMOD.Links) do
		pcall(TransferLink, l)
	end
end)

-- Диагностика устройства под прицелом
concommand.Add("sbjmod_test_energy", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local e = ply:GetEyeTrace().Entity
	if not IsValid(e) then
		print("[SBJMOD] Под прицелом ничего.")
		return
	end

	print("[SBJMOD] === Диагностика: " .. e:GetClass() .. " ===")
	print("Роль: " .. GetRole(e) .. " | Тип: " .. tostring(SB_JMOD.Identify(e)))

	if IsResNode(e) then
		print("resource_node: окно в RD-сеть, ресурс energy")
		if RD and isfunction(RD.GetResourceAmount) then
			local ok, v = pcall(RD.GetResourceAmount, e, "energy")
			print("RD.GetResourceAmount -> ok=" .. tostring(ok) .. " val=" .. tostring(ok and v or ("err:" .. tostring(v))))
		else
			print("RD: глобальной таблицы нет!")
		end
		if isfunction(e.GetNetworkCapacity) then
			local okc, c = pcall(e.GetNetworkCapacity, e, "energy")
			print("GetNetworkCapacity -> ok=" .. tostring(okc) .. " val=" .. tostring(okc and c or ("err:" .. tostring(c))))
		end
		if not (RD and isfunction(RD.GetResourceAmount)) then
			print("Внимание: узел без связи в RD-сети не может обмениваться энергией.")
		end
	elseif isfunction(e.GetElectricity) then
		local ok, v = pcall(e.GetElectricity, e)
		print("GetElectricity -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
		print("MaxElectricity = " .. tostring(e.MaxElectricity))
	elseif isfunction(e.GetResourceAmount) then
		local ok, v = pcall(e.GetResourceAmount, e, "energy")
		print("GetResourceAmount(energy) -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
		if isfunction(e.GetNetworkCapacity) then
			local okc, c = pcall(e.GetNetworkCapacity, e, "energy")
			print("GetNetworkCapacity -> ok=" .. tostring(okc) .. " val=" .. tostring(okc and c or ("err:" .. tostring(c))))
		end
	end
	print("[SBJMOD] === Конец диагностики ===")
end)

print("[SBJMOD] Модуль transfer v7.3 загружен: JMod/SB/CAF + resource_node (RD-сеть)")
