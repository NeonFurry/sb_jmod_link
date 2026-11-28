--[[
	SB <-> JMod Link — мост к CAF / Resource Distribution (сервер).
	Подтверждённые функции RD3 из исходников Spacebuild:
	  GetEntityTable, GetResourceAmount, GetNetResourceAmount,
	  GetUnitCapacity, GetNetNetworkCapacity, ConsumeResource,
	  ConsumeNetResource, SupplyResource, SupplyNetResource.
]]

SB_JMOD.Caf = SB_JMOD.Caf or {}
SB_JMOD.CafLoaded = true

local C = SB_JMOD.Caf
C.Available = false
local RD = nil

local function TryInit()
	local ok, caf = pcall(function() return CAF.GetAddon("Resource Distribution") end)
	if not ok or not istable(caf) then return false end
	RD = caf
	C.RD = RD
	C.Available = true

	-- Тип «caf» регистрируется в реестре ядра (приоритет 30: после
	-- fusion и resource_node, но до определения по методам устройства —
	-- методы JMod важнее, поэтому у них приоритет 40).
	if isfunction(SB_JMOD.AddIdentifier) then
		SB_JMOD.AddIdentifier("caf", 30, function(e)
			if not IsValid(e) then return nil end
			if e.IsNode then return "caf" end
			local ok3, t = pcall(RD.GetEntityTable, e)
			if ok3 and istable(t) and t.ent ~= nil then return "caf" end
			return nil
		end)
	end

	function C.NetID(e)
		if not IsValid(e) then return nil end
		if e.IsNode and isnumber(e.netid) then return e.netid end
		local ok, t = pcall(RD.GetEntityTable, e)
		if ok and istable(t) and isnumber(t.network) and t.network ~= 0 then return t.network end
		return nil
	end

	function C.Amount(e, res)
		local netid = C.NetID(e)
		if netid then
			local ok, v = pcall(RD.GetNetResourceAmount, netid, res)
			if ok and isnumber(v) then return v end
		end
		local ok2, v2 = pcall(RD.GetResourceAmount, e, res, false)
		if ok2 and isnumber(v2) then return v2 end
		return 0
	end

	function C.Capacity(e, res)
		local netid = C.NetID(e)
		if netid then
			local ok, v = pcall(RD.GetNetNetworkCapacity, netid, res)
			if ok and isnumber(v) then return v end
		end
		local ok2, v2 = pcall(RD.GetUnitCapacity, e, res)
		if ok2 and isnumber(v2) then return v2 end
		return 1e9
	end

	function C.Consume(e, res, amount)
		local netid = C.NetID(e)
		if netid then
			local ok, got = pcall(RD.ConsumeNetResource, netid, res, amount)
			return (ok and isnumber(got)) and got or 0
		end
		local ok2, got2 = pcall(RD.ConsumeResource, e, res, amount)
		return (ok2 and isnumber(got2)) and got2 or 0
	end

	function C.Supply(e, res, amount)
		local netid = C.NetID(e)
		if netid then
			local ok, left = pcall(RD.SupplyNetResource, netid, res, amount)
			if ok and isnumber(left) then return amount - left end
			return ok and amount or 0
		end
		local ok2, left2 = pcall(RD.SupplyResource, e, res, amount)
		if ok2 and isnumber(left2) then return amount - left2 end
		return amount
	end

	if not SB_JMOD.HotReloading then
		print("[SBJMOD] Модуль CAF: Resource Distribution найден")
	end
	return true
end

if not TryInit() then
	if not SB_JMOD.HotReloading then
		print("[SBJMOD] Модуль CAF: Resource Distribution пока не загружен — жду аддон...")
	end
	timer.Create("SBJMOD_CafInit", 1, 30, function()
		if TryInit() then timer.Remove("SBJMOD_CafInit") end
	end)
end
