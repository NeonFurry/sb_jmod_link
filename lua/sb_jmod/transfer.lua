--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Transfer (v9.2)
	Поддержка: JMod, Spacebuild/SB, CAF/RD3 + resource_node (SB3/CAF)

	Сверено по исходникам:
	  SpaceBuild  https://github.com/spacebuild/spacebuild
	    lua/caf/addons/server/resourcedistribution.lua, lifesupport.lua
	  JMod        https://github.com/Jackarunda/gmod
	    ent_jack_gmod_ezmachine_base.lua, ent_jack_gmod_ezbattery.lua

	Что выяснилось и учтено:
	  - RD.GetResourceAmount(ent, res, sumconnectednets): третий аргумент
	    по умолчанию TRUE и суммирует все связанные сети. Для «заряда
	    этого прибора» передаём false.
	  - RD.GetNetworkCapacity(ent, res, sumconnectednets) существует
	    (в caf.lua его раньше не было в списке подтверждённых).
	  - RD.SupplyResource/ConsumeResource возвращают left/consumed;
	    заряд меняем дельтой, как требует RD3.
	  - Ресурсы SB: energy, water, oxygen, nitrogen, hydrogen,
	    carbon dioxide, steam, heavy water, liquid nitrogen.
	    Никаких air/food/waste в RD нет.
	  - Life Support: классы base_air_exchanger, base_temperature_exchanger,
	    generator_recycler_*, generator_gas_o2h_water, generator_gas_steam;
	    «life_support_*», «recycler», «scrubber» как классы не существуют.
	  - JMod: машины (генераторы, power bank, турели) имеют
	    GetElectricity/SetElectricity/MaxElectricity через NetworkVar.
	    Батарея ent_jack_gmod_ezbattery — ресурсная сущность без этих
	    методов: GetResource/SetResource/MaxResource, EZsupplies == "power".

	Новое в 9.2: мультиресурсные связи (l.res), таблица ролей по
	реальным классам SB, чтение JMod-батарей как источника энергии.

	Правила сети (строго):
	  генератор -> банк/потребитель : МОЖНО (до ёмкости принимающего)
	  банк <-> банк                 : равный делёж 1-в-1, до единицы
	  потребитель -> кто угодно     : ЗАПРЕЩЕНО (только принимает)
	  банк -> генератор             : ЗАПРЕЩЕНО
	  генератор <-> генератор       : ЗАПРЕЩЕНО

	Интервал: 0,1 секунды. Лог: sbjmod_transferlog 1
	Диагностика: sbjmod_test_energy (алиас: sbjmod_test).
	HUD: SB_JMOD.CollectResources — список ресурсов прибора для клиента.
--------------------------------------------------------------------]]

local cvLog = CreateConVar("sbjmod_transferlog", "0", FCVAR_ARCHIVE,
	"Показывать перекачку в консоли (0/1)")

local cvDefRes = CreateConVar("sbjmod_default_resource", "auto", FCVAR_ARCHIVE,
	"Ресурс новых связей: auto | energy | water | oxygen | nitrogen | hydrogen | carbon dioxide | steam | heavy water | liquid nitrogen")

-- Порядок предпочтения при автоопределении ресурса.
-- Набор — канонические имена SB (RD.AddProperResourceName в lifesupport.lua).
local RES_ORDER = {
	"energy", "water", "oxygen", "nitrogen", "hydrogen",
	"carbon dioxide", "steam", "heavy water", "liquid nitrogen",
}

-- ======== Доступ к Resource Distribution (SB3/CAF) ========

local function GetRD()
	if RD and isfunction(RD.GetResourceAmount) then return RD end
	if CAF and isfunction(CAF.GetAddon) then
		local ok, rd = pcall(CAF.GetAddon, "Resource Distribution")
		if ok and rd and isfunction(rd.GetResourceAmount) then return rd end
	end
	return nil
end

-- Ёмкость по ресурсу: сеть RD -> юнит-ёмкость -> методы энтити -> 10000
local function GetCap(e, rd, res)
	res = res or "energy"
	local cap
	if rd and isfunction(rd.GetNetworkCapacity) then
		-- false: только своя сеть, без соседних (см. заголовок)
		local ok, c = pcall(rd.GetNetworkCapacity, e, res, false)
		if ok and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
	end
	if not cap and rd and isfunction(rd.GetUnitCapacity) then
		local ok, c = pcall(rd.GetUnitCapacity, e, res)
		if ok and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
	end
	if not cap and isfunction(e.GetNetworkCapacity) then
		local ok, c = pcall(e.GetNetworkCapacity, e, res, false)
		if ok and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
	end
	cap = cap or 10000
	-- Лимит энергии Fusion Generators (sbjmod_fusion_energy_limit).
	-- Относится только к энергии: GetNetworkCapacity возвращает maxvalue
	-- сети, а лимит энергии в RD3 — это ПОТОЛОК СЕТЕВОГО значения
	-- (nettable value), поэтому он ограничивает и перекачку во всю сеть.
	local F = SB_JMOD.Fusion
	if res == "energy" and F and isfunction(F.Is) and isfunction(F.Capacity) and F.Is(e) then
		cap = F.Capacity(cap)
	end
	return cap
end

-- ======== Расширение ядра: resource_node (SB3/CAF) ========

local IsResNode = function(e)
	return string.lower(e:GetClass() or "") == "resource_node"
end

if isfunction(SB_JMOD.AddIdentifier) then
	SB_JMOD.AddIdentifier("sbres", 20, function(e)
		if IsResNode(e) then return "sbres" end
		return nil
	end)
end

-- ======== Ресурсы устройства (RD entity table) ========

local function ResourcesOf(e)
	local set = {}
	if not IsValid(e) then return set end
	local rd = GetRD()
	if rd and isfunction(rd.GetEntityTable) then
		local ok, t = pcall(rd.GetEntityTable, e)
		if ok and istable(t) and istable(t.resources) then
			for res in pairs(t.resources) do set[res] = true end
		end
	end
	return set
end

--- Выбор ресурса новой связи: выбор игрока (sbjmod_res) > конвар >
--- общий ресурс устройств по RES_ORDER.
function SB_JMOD.ChooseResource(a, b, ply)
	local forced
	if IsValid(ply) and isstring(ply.SBJMOD_Res) then
		forced = ply.SBJMOD_Res
	else
		local s = cvDefRes and string.lower(cvDefRes:GetString() or "") or ""
		if s ~= "" and s ~= "auto" then forced = s end
	end

	local ra = ResourcesOf(a)
	local rb = ResourcesOf(b)
	local hasA, hasB = next(ra) ~= nil, next(rb) ~= nil

	if forced then
		if forced == "energy" then return "energy" end
		if (not hasA or ra[forced]) and (not hasB or rb[forced]) then return forced end
		return "energy"
	end

	for _, res in ipairs(RES_ORDER) do
		if ra[res] and rb[res] then return res end
	end
	return "energy"
end

-- ======== Чтение заряда: возвращает текущее значение и ёмкость ========

--- JMod (и современный, и Legacy): порядок путей чтения заряда.
--- 1) методы машины, 2) старый GetEZsupplies("power"), 3) ресурс power,
--- 4) поля-фолбэки. Порядок сверен с Jackarunda/gmod и покрывает
--- legacy-сборки, где набор методов отличается.
local function ClampMax(v, def)
	local m = tonumber(v) or def
	if m <= 0 then m = def end
	return m
end

local function GetJModCharge(e)
	if isfunction(e.GetElectricity) then
		local ok, v = pcall(e.GetElectricity, e)
		if ok and v ~= nil and tonumber(v) then
			return tonumber(v), ClampMax(e.MaxElectricity, 100)
		end
	end

	if isfunction(e.GetEZsupplies) then
		local ok, v = pcall(e.GetEZsupplies, e, "power")
		if ok and v ~= nil and tonumber(v) then
			return tonumber(v), ClampMax(e.MaxElectricity or e.MaxResource, 100)
		end
	end

	if isfunction(e.GetResource) and e.EZsupplies == "power" then
		local ok, v = pcall(e.GetResource, e)
		if ok and v ~= nil and tonumber(v) then
			return tonumber(v), ClampMax(e.MaxResource, 100)
		end
	end

	-- JMod Legacy: заряд — обычное поле BatteryCharge (проверено по
	-- ent_jack_turretbattery, ent_jack_turret_base, ent_jack_teslasentry,
	-- ent_jack_terminal, ent_jack_aidcomm). Ёмкость — MaxCharge (турели)
	-- или BatteryMaxCharge (батареи/терминал).
	if tonumber(e.BatteryCharge) ~= nil then
		return tonumber(e.BatteryCharge), ClampMax(e.MaxCharge or e.BatteryMaxCharge, 100)
	end

	local cur = tonumber(e.Electricity) or tonumber(e.Resource)
	if cur then
		return cur, ClampMax(e.MaxElectricity or e.MaxResource, 100)
	end

	return nil
end

--- Подпись ресурса для HUD: повторяет порядок чтения заряда.
local function JModPowerLabel(e)
	if isfunction(e.GetElectricity) then return "electricity" end
	if isfunction(e.GetEZsupplies) then return "power" end
	if isfunction(e.GetResource) and e.EZsupplies == "power" then return "power" end
	if tonumber(e.BatteryCharge) ~= nil then return "charge" end
	return "electricity"
end

local function GetCharge(e, t, res)
	res = res or "energy"

	if res == "energy" and (t == "jmod" or t == "both") then
		return GetJModCharge(e)
	end

	-- sbres / sb / caf / fusion — единый устойчивый путь: RD -> методы энтити
	local rd = GetRD()
	if rd then
		local ok, cur = pcall(rd.GetResourceAmount, e, res, false)
		if ok and isnumber(cur) then
			return cur, GetCap(e, rd, res)
		end
	end
	if isfunction(e.GetResourceAmount) then
		local ok, cur = pcall(e.GetResourceAmount, e, res)
		if ok and isnumber(cur) then
			return cur, GetCap(e, nil, res)
		end
	end
	return nil
end

-- ======== Запись заряда ========
-- В RD3 нет SetResourceAmount: количество меняется дельтой через
-- SupplyResource / ConsumeResource (они обновляют и сеть, и счётчики).

local function SetCharge(e, t, val, res)
	res = res or "energy"
	val = math.max(0, math.floor(val + 0.5))

	if res == "energy" and (t == "jmod" or t == "both") then
		if isfunction(e.SetElectricity) then
			pcall(e.SetElectricity, e, val)
		elseif isfunction(e.SetResource) and e.EZsupplies == "power" then
			-- Батарея/ящик JMod: обычный сеттер, без EZ-удаления сущности
			pcall(e.SetResource, e, math.floor(val))
		elseif tonumber(e.BatteryCharge) ~= nil then
			-- JMod Legacy: заряд — обычное поле. Пишем напрямую (у этих
			-- сущностей ExternalCharge ведёт себя по-разному: батарея
			-- ставит полный заряд, терминал прибавляет amt), и оживляем
			-- «мёртвую» батарею, как это делает её же ExternalCharge.
			local max = tonumber(e.MaxCharge) or tonumber(e.BatteryMaxCharge) or val
			e.BatteryCharge = math.Clamp(val, 0, math.max(max, 0))
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
		elseif isfunction(e.TryLoadResource) then
			-- Штатный приёмник: умеет только пополнять (лимит 1 раз/сек)
			local cur = GetJModCharge(e)
			local diff = val - (cur or 0)
			if diff > 0 then pcall(e.TryLoadResource, e, "power", diff) end
		elseif isfunction(e.SetEZsupplies) then
			-- Последний сеттер: при значении < 1 ресурсная сущность JMod
			-- удаляет себя, поэтому не отдаём меньше единицы
			pcall(e.SetEZsupplies, e, "power", math.max(1, math.floor(val)))
		elseif isfunction(e.GetElectricity) or e.MaxElectricity then
			e.Electricity = val
		else
			e.Resource = math.floor(val)
		end
		return
	end

	local cur = GetCharge(e, t, res)
	if cur == nil then return end
	local diff = val - cur
	if diff == 0 then return end

	local rd = GetRD()
	if diff > 0 then
		if rd and isfunction(rd.SupplyResource) then
			pcall(rd.SupplyResource, e, res, diff)
		elseif isfunction(e.SupplyResource) then
			pcall(e.SupplyResource, e, res, diff)
		end
	else
		if rd and isfunction(rd.ConsumeResource) then
			pcall(rd.ConsumeResource, e, res, -diff)
		elseif isfunction(e.ConsumeResource) then
			pcall(e.ConsumeResource, e, res, -diff)
		end
	end
end

-- ======== Роли устройств ========
-- Переопределения по классам проверены по исходникам SB/JMod.
-- Ключ — подстрока имени класса, значение — таблица [ресурс] = роль.
-- Дополнять можно из консоли/своего аддона: SB_JMOD.DeviceRoles.
SB_JMOD.DeviceRoles = SB_JMOD.DeviceRoles or {
	["generator_energy_fusion"] = { energy = "gen", water = "cons", steam = "gen" },
	["generator_recycler_"] = { energy = "cons", ["liquid nitrogen"] = "gen", nitrogen = "gen", water = "gen" },
	["generator_gas_o2h_water"] = { energy = "cons", water = "cons", hydrogen = "gen", oxygen = "gen" },
	["generator_gas_steam"] = { energy = "cons", water = "cons", steam = "gen" },
	["base_air_exchanger"] = { energy = "cons", oxygen = "cons", ["carbon dioxide"] = "gen" },
	-- JMod-батарея — расходуемый источник: отдаёт заряд прибору до нуля,
	-- а не выравнивается с ним 1:1 как банк.
	["ent_jack_gmod_ezbattery"] = { energy = "gen" },
}

local function RoleOverride(e, res)
	local cls = string.lower(e:GetClass() or "")
	for pat, map in pairs(SB_JMOD.DeviceRoles) do
		if string.find(cls, pat, 1, true) then
			local r = map[res]
			if r then return r end
		end
	end
	return nil
end

local function GetRole(e, res)
	res = res or "energy"

	local over = RoleOverride(e, res)
	if over then return over end

	local cls = string.lower(e:GetClass() or "")

	if res ~= "energy" then
		-- Жидкости/газы: хранилища копят, генераторы производят,
		-- теплообменники потребляют.
		if string.find(cls, "storage_", 1, true) or cls == "resource_node" then
			return "bank"
		end
		if string.find(cls, "generator_", 1, true) then
			return "gen"
		end
		if string.find(cls, "exchanger", 1, true) then
			return "cons"
		end
		return "bank"
	end

	local F = SB_JMOD.Fusion
	if F and isfunction(F.Is) and F.Is(e) then return "gen" end

	-- JMod Legacy: собственный заряд BatteryCharge есть у турелей, самого
	-- предмета-батареи, терминала, теслы и aidcomm — все они только
	-- потребляют, поэтому наполняем их, но не тянем из них.
	if tonumber(e.BatteryCharge) ~= nil then return "cons" end

	if string.find(cls, "turret", 1, true)
		or string.find(cls, "sentry", 1, true)
		or string.find(cls, "consumer", 1, true) then
		return "cons"
	end
	if string.find(cls, "generator", 1, true)
		or string.find(cls, "gen_", 1, true)
		or string.find(cls, "_gen", 1, true)
		or string.find(cls, "powersource", 1, true)
		or string.find(cls, "reactor", 1, true) then
		return "gen"
	end
	-- resource_node, банки, всё остальное — накопители
	return "bank"
end

SB_JMOD.GetRole = GetRole -- доступно модулям (fusion.lua)

-- ======== Перекачка по одной связи ========

local function Move(src, srcT, dst, dstT, give, res)
	if give <= 0 then return end
	local sCur = GetCharge(src, srcT, res)
	local dCur, dCap = GetCharge(dst, dstT, res)
	if not sCur or not dCur or not dCap then return end
	-- Не отдаём больше, чем источник имеет, и не вливаем больше,
	-- чем принимающий может вместить (иначе ресурс теряется)
	give = math.min(give, sCur, dCap - dCur)
	if give <= 0 then return end
	SetCharge(src, srcT, sCur - give, res)
	SetCharge(dst, dstT, dCur + give, res)
	if cvLog:GetBool() then
		print(("[SBJMOD] %s -> %s [%s]: +%d"):format(src:GetClass(), dst:GetClass(), res or "energy", give))
	end
end

--- Оба конца в одной RD-сети: ресурс у них общий, перекачивать нечего.
--- Без этой проверки дельта-запись даёт двойное начисление: сначала
--- списываем из сети по старому значению источника, затем добавляем
--- получателю по старому значению приёмника — сеть получает лишнее.
local function SameNet(a, b)
	local rd = GetRD()
	if not rd or not isfunction(rd.GetEntityTable) then return false end
	local okA, ta = pcall(rd.GetEntityTable, a)
	local okB, tb = pcall(rd.GetEntityTable, b)
	if not (okA and okB and istable(ta) and istable(tb)) then return false end
	local na = tonumber(ta.network) or 0
	local nb = tonumber(tb.network) or 0
	return na ~= 0 and na == nb
end

local function TransferLink(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end

	local res = isstring(l.res) and l.res or "energy"
	local ta = SB_JMOD.Identify and SB_JMOD.Identify(l.a) or nil
	local tb = SB_JMOD.Identify and SB_JMOD.Identify(l.b) or nil
	if not ta or not tb then return end

	-- Одна RD-сеть: ресурс уже общий (защита от «размножения» дельтой)
	if SameNet(l.a, l.b) then return end

	local roleA = GetRole(l.a, res)
	local roleB = GetRole(l.b, res)

	-- генератор <-> генератор: ЗАПРЕЩЕНО
	if roleA == "gen" and roleB == "gen" then return end

	local curA, capA = GetCharge(l.a, ta, res)
	local curB, capB = GetCharge(l.b, tb, res)
	if not curA or not curB or not capA or not capB then return end

	-- генератор -> банк/потребитель: заполняем принимающий ДО ЕГО ЁМКОСТИ
	if roleA == "gen" then
		local free = capB - curB
		if free > 0 then Move(l.a, ta, l.b, tb, math.min(free, curA), res) end
		return
	end
	if roleB == "gen" then
		local free = capA - curA
		if free > 0 then Move(l.b, tb, l.a, ta, math.min(free, curB), res) end
		return
	end

	-- потребитель -> кто угодно: ЗАПРЕЩЕНО (в т.ч. cons -> cons).
	-- банк -> потребитель: только пополнение потребителя
	if roleA == "cons" then
		if roleB ~= "cons" then
			local free = capA - curA
			if free > 0 then Move(l.b, tb, l.a, ta, math.min(free, curB), res) end
		end
		return
	end
	if roleB == "cons" then
		local free = capB - curB
		if free > 0 then Move(l.a, ta, l.b, tb, math.min(free, curA), res) end
		return
	end

	-- банк <-> банк: равный делёж 1-в-1, до единицы
	if capA <= 0 or capB <= 0 then return end
	local total = curA + curB
	if total <= 0 then return end

	local wantA = math.min(math.floor(total / 2), capA)
	local wantB = math.min(total - wantA, capB)
	if wantB < total - wantA then
		wantA = math.min(total - wantB, capA)
	end

	if curA > wantA then Move(l.a, ta, l.b, tb, curA - wantA, res) end
	if curB > wantB then Move(l.b, tb, l.a, ta, curB - wantB, res) end
end

timer.Create("SBJMOD_Transfer", 0.1, 0, function()
	if not SB_JMOD.Links or #SB_JMOD.Links == 0 then return end
	for _, l in ipairs(SB_JMOD.Links) do
		pcall(TransferLink, l)
	end
end)

-- ======== Ресурсы прибора для HUD (сервер -> клиент) ========

--- Возвращает список { res, value, cap } для прибора.
--- JMod: Electricity (машины) или power (батареи/ящики).
function SB_JMOD.CollectResources(e)
	if not IsValid(e) then return nil end
	local list = {}

	local rd = GetRD()
	if rd and isfunction(rd.GetEntityTable) then
		local ok, t = pcall(rd.GetEntityTable, e)
		if ok and istable(t) and istable(t.resources) then
			-- У прибора в сети реальные запасы лежат в nettable: в таблице
			-- сущности value/maxvalue описывают только его собственный бак
			local netid = tonumber(t.network) or 0
			local nt = (netid ~= 0 and isfunction(rd.GetNetTable)) and rd.GetNetTable(netid) or nil
			local netres = istable(nt) and nt.resources or nil

			for res, d in pairs(t.resources) do
				if istable(d) and isnumber(d.value) then
					local value, cap = d.value, tonumber(d.maxvalue) or 0
					local nr = netres and netres[res]
					if istable(nr) and isnumber(nr.value) then
						value, cap = nr.value, tonumber(nr.maxvalue) or cap
					end
					list[#list + 1] = {
						res = res,
						value = math.floor(value),
						cap = math.floor(cap),
					}
				end
			end
		end
	end

	if #list == 0 then
		-- JMod (в т.ч. Legacy): машины, ресурсные сущности, поля
		local cur, cap = GetJModCharge(e)
		if cur then
			list[1] = { res = JModPowerLabel(e), value = math.floor(cur), cap = math.floor(cap or 0) }
		end
	end

	if #list == 0 then return nil end
	table.sort(list, function(x, y) return tostring(x.res) < tostring(y.res) end)
	return list
end

-- ======== Выбор ресурса игроком ========

local function ValidResourceName(r)
	for _, name in ipairs(RES_ORDER) do
		if r == name then return true end
	end
	return false
end

concommand.Add("sbjmod_res", function(ply, _, args)
	if not IsValid(ply) then return end
	local r = string.lower(table.concat(args, " "):Trim())

	if r == "" then
		ply.SBJMOD_Res = nil
		ply:ChatPrint("[SBJMOD] Ресурс следующих связей: авто (по общим ресурсам устройств).")
		return
	end

	if not ValidResourceName(r) then
		ply:ChatPrint("[SBJMOD] Ресурсы SB: " .. table.concat(RES_ORDER, ", "))
		ply:ChatPrint("[SBJMOD] Имена из двух слов берите в кавычки: sbjmod_res \"carbon dioxide\". Без аргумента — авто.")
		return
	end

	ply.SBJMOD_Res = r
	ply:ChatPrint("[SBJMOD] Ресурс следующих связей: " .. r)
end)

-- ======== Диагностика устройства под прицелом ========

local function DumpDevice(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	if not IsValid(ply) then return end
	local e = ply:GetEyeTrace().Entity
	if not IsValid(e) then
		print("[SBJMOD] Под прицелом ничего.")
		return
	end

	local t = SB_JMOD.Identify and SB_JMOD.Identify(e) or nil

	print("[SBJMOD] === Диагностика: " .. e:GetClass() .. " ===")
	print("Тип: " .. tostring(t))

	local roles = {}
	for _, res in ipairs(RES_ORDER) do
		roles[#roles + 1] = res .. "=" .. GetRole(e, res)
	end
	print("Роли: " .. table.concat(roles, " "))

	if IsResNode(e) then
		print("resource_node: окно в RD-сеть")
	end

	local list = SB_JMOD.CollectResources(e)
	if list then
		for _, r in ipairs(list) do
			print(("  %s: %s / %s"):format(r.res, tostring(r.value), tostring(r.cap)))
		end
	else
		print("  ресурсы недоступны (нет RD и нет JMod-полей)")
	end

	if isfunction(e.GetResource) and e.EZsupplies then
		print("  JMod EZsupplies: " .. tostring(e.EZsupplies))
	end

	print("[SBJMOD] === Конец диагностики ===")
end

concommand.Add("sbjmod_test_energy", DumpDevice)
concommand.Add("sbjmod_test", DumpDevice)

if not SB_JMOD.HotReloading then
	print("[SBJMOD] Модуль transfer v9.2 загружен: мультиресурсные связи по API SpaceBuild/JMod")
end
