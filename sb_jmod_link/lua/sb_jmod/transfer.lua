--[[
	SB <-> JMod Link — модуль перекачки (сервер).
	Типы устройств: jmod (электричество JMod), sb (энергия Spacebuild),
	caf (ресурсы CAF/RD3-сети).
]]

SB_JMOD.TransferLoaded = true

local function JModAmount(e)
	local ok, v = pcall(e.GetElectricity, e)
	if ok and isnumber(v) then return v end
	return 0
end

local function JModCapacity(e)
	if isnumber(e.MaxElectricity) then return e.MaxElectricity end
	if isfunction(e.GetMaxElectricity) then
		local ok, v = pcall(e.GetMaxElectricity, e)
		if ok and isnumber(v) then return v end
	end
	return math.huge
end

local function SBAmount(e, res)
	local ok, v = pcall(e.GetResourceAmount, e, res)
	if ok and isnumber(v) then return v end
	return 0
end

local function SBCapacity(e, res)
	if isfunction(e.GetResourceCapacity) then
		local ok, v = pcall(e.GetResourceCapacity, e, res)
		if ok and isnumber(v) then return v end
	end
	if istable(e.C) and istable(e.C[res]) and isnumber(e.C[res].max) then
		return e.C[res].max
	end
	return 1e9
end

local function CafAmount(e, res)
	local C = SB_JMOD.Caf
	if not C or not C.Available then return 0 end
	return C.Amount(e, res)
end

local function CafCapacity(e, res)
	local C = SB_JMOD.Caf
	if not C or not C.Available then return 1e9 end
	return C.Capacity(e, res)
end

local function Amount(e, kind, res)
	if kind == "jmod" then return JModAmount(e) end
	if kind == "caf" then return CafAmount(e, res) end
	return SBAmount(e, res)
end

local function Capacity(e, kind, res)
	if kind == "jmod" then return JModCapacity(e) end
	if kind == "caf" then return CafCapacity(e, res) end
	return SBCapacity(e, res)
end

function SB_JMOD.Transfer(from, to, amount, res)
	res = res or "energy"
	local fk, tk = SB_JMOD.Identify(from), SB_JMOD.Identify(to)
	if not fk or not tk then return 0 end
	if fk == "both" then fk = "sb" end
	if tk == "both" then tk = "sb" end

	local have = Amount(from, fk, res)
	local free = Capacity(to, tk, res) - Amount(to, tk, res)
	local move = math.min(amount, have, math.max(free, 0))
	if move <= 0 then return 0 end

	if fk == "caf" then
		move = SB_JMOD.Caf.Consume(from, res, move)
	elseif fk == "jmod" then
		pcall(from.SetElectricity, from, have - move)
	else
		pcall(from.SetResourceAmount, from, res, have - move)
	end
	if move <= 0 then return 0 end

	if tk == "caf" then
		local got = SB_JMOD.Caf.Supply(to, res, move)
		if got < move then
			local back = move - got
			if fk == "caf" then
				SB_JMOD.Caf.Supply(from, res, back)
			elseif fk == "jmod" then
				pcall(from.SetElectricity, from, JModAmount(from) + back)
			else
				pcall(from.SetResourceAmount, from, res, Amount(from, fk, res) + back)
			end
			return got
		end
	elseif tk == "jmod" then
		pcall(to.SetElectricity, to, JModAmount(to) + move)
	else
		pcall(to.SetResourceAmount, to, res, Amount(to, tk, res) + move)
	end

	return move
end

function SB_JMOD.Pump(l)
	local ka, kb = SB_JMOD.Identify(l.a), SB_JMOD.Identify(l.b)
	if not ka or not kb then return end
	local res = (ka == "caf" or kb == "caf") and (l.res or "energy") or "energy"
	local amA = Amount(l.a, ka == "both" and "sb" or ka, res)
	local amB = Amount(l.b, kb == "both" and "sb" or kb, res)
	local rate = math.Clamp(l.rate or 50, 1, 100000)
	if amA > amB then
		SB_JMOD.Transfer(l.a, l.b, math.min(rate, amA - amB), res)
	elseif amB > amA then
		SB_JMOD.Transfer(l.b, l.a, math.min(rate, amB - amA), res)
	end
end

print("[SBJMOD] Модуль перекачки загружен (v" .. SB_JMOD.Version .. ")")
