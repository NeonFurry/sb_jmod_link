--[[--------------------------------------------------------------------
	SB <-> JMod Link v9.2
	Беспроводная перекачка энергии и ресурсов: Spacebuild (RD3) <-> JMod.
	Совместимость с CAF (Resource Distribution): устройства распознаются
	через реестр определителей, Auto Link Tool умеет подключать
	JMod-банки к нодам RD-сети.
	Модули: transfer.lua (насос), rope.lua (совместимость, трос отключён),
	caf.lua (мост RD), autolink.lua (патч Auto Link Tool),
	fusion.lua (Fusion Generator: без урона, вода, лимиты).

	Новое в 9.1/9.2 (сверено по исходникам SpaceBuild и Jackarunda/gmod):
	  - Связи несут ресурс (l.res): energy/water/oxygen/nitrogen/... —
	    см. transfer.lua v9.2 и команду sbjmod_res.
	  - JMod-батареи (ent_jack_gmod_ezbattery) распознаются как источник
	    энергии: у них нет GetElectricity, заряд лежит в GetResource().
	  - HUD показывает ресурсы прибора под прицелом
	    (sb_jmodlink_hud_res, по умолчанию 1).
	  - Модуль EZ-Battery переписан под RD3 и TryLoadResource,
	    по умолчанию выключен (sbjmod_ezbat_touch 1).

	Новое в 9.0:
	  - Реестр определителей SB_JMOD.AddIdentifier вместо наращивания
	    обёрток над SB_JMOD.Identify (хотрелоад не копит слои).
	  - Права на связи: sbjmod_open_links (0 = только свои/админ).
	  - Синхронизация связей: только при изменении и при заходе,
	    счётчик UInt16.
	  - Чистка связей: EntityRemoved + PostCleanupMap + Prune.
--------------------------------------------------------------------]]

SB_JMOD = SB_JMOD or {}
SB_JMOD.Version = "9.6"
SB_JMOD.Links = SB_JMOD.Links or {}
SB_JMOD.NextID = SB_JMOD.NextID or 1
SB_JMOD.Identifiers = SB_JMOD.Identifiers or {}
SB_JMOD.IdentOrder = nil

local NET_NAME = "SBJMOD_Links"
local NET_INTERVAL = 5
local TOOL_MODE = "sb_jmodlink"
local MAX_SYNC_LINKS = 4096

SB_JMOD.NetReady = false
SB_JMOD.SyncDirty = true

--------------------------------------------------------------------
-- ОПРЕДЕЛЕНИЕ ТУЛА (единый источник)
--------------------------------------------------------------------
SB_JMOD.ToolDef = SB_JMOD.ToolDef or {}
local D = SB_JMOD.ToolDef

D.Mode = TOOL_MODE
D.Category = "Tool"
D.Name = "SB <-> JMod Link"
D.ClientConVar = { hud_links = "0" }

D.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" },
	{ name = "0", stage = 0 },
	{ name = "1", stage = 1 },
	{ name = "2", stage = 2 },
}

D.SetStage = function(self, s)
	self.Stage = s
	if SERVER then
		local wep = self:GetWeapon()
		if IsValid(wep) then wep:SetNW2Int("SBJMOD_Stage", s) end
	end
end

D.GetStage = function(self)
	local wep = self:GetWeapon()
	if IsValid(wep) then return wep:GetNW2Int("SBJMOD_Stage", self.Stage or 0) end
	return self.Stage or 0
end

D.LeftClick = function(self, tr)
	if not SERVER then return true end
	local ply = self:GetOwner()
	if not IsValid(ply) then return true end
	local ent = (tr and IsValid(tr.Entity)) and tr.Entity or nil

	if not IsValid(ent) then
		ply:ChatPrint("[SBJMOD] Ни по чему не попали.")
		return true
	end

	if not SB_JMOD.Identify(ent) then
		ply:ChatPrint("[SBJMOD] Это не устройство SB/JMod/CAF: " .. ent:GetClass())
		return true
	end

	local sel = SB_JMOD.Sel(ply)

	if not IsValid(sel.first) then
		sel.first = ent
		self:SetStage(1)
		ply:ChatPrint("[SBJMOD] Выбрано: " .. ent:GetClass() .. " — второй ЛКМ создаст связь.")
		return true
	end

	if ent == sel.first and not IsValid(sel.second) then
		ply:ChatPrint("[SBJMOD] Это уже первая цель — выберите другое устройство.")
		return true
	end

	local target = IsValid(sel.second) and sel.second or ent
	local ok, msg, res = SB_JMOD.CreateLink(sel.first, target, ply)
	if ok then
		ply:ChatPrint(("[SBJMOD] Связь создана: %s <-> %s [%s]"):format(
			sel.first:GetClass(), target:GetClass(), tostring(res or "energy")))
	else
		ply:ChatPrint("[SBJMOD] Ошибка: " .. tostring(msg))
	end
	SB_JMOD.SelClear(ply)
	self:SetStage(0)
	return true
end

D.RightClick = function(self, tr)
	if not SERVER then return true end
	local ply = self:GetOwner()
	if not IsValid(ply) then return true end
	local ent = (tr and IsValid(tr.Entity)) and tr.Entity or nil

	if not IsValid(ent) then
		ply:ChatPrint("[SBJMOD] Ни по чему не попали.")
		self:SetStage(0)
		return true
	end

	if not SB_JMOD.Identify(ent) then
		ply:ChatPrint("[SBJMOD] Это не устройство SB/JMod/CAF: " .. ent:GetClass())
		return true
	end

	local sel = SB_JMOD.Sel(ply)

	if not IsValid(sel.first) then
		sel.first = ent
		sel.second = nil
		self:SetStage(1)
		ply:ChatPrint("[SBJMOD] Цель 1: " .. ent:GetClass() .. " — теперь ПКМ по второй цели.")
	elseif not IsValid(sel.second) then
		if ent == sel.first then
			ply:ChatPrint("[SBJMOD] Это уже первая цель — выберите другую.")
			return true
		end
		sel.second = ent
		self:SetStage(2)
		ply:ChatPrint("[SBJMOD] Цель 2: " .. ent:GetClass() .. " — ещё ПКМ для создания связи.")
	else
		local ok, msg, res = SB_JMOD.CreateLink(sel.first, sel.second, ply)
		if ok then
			ply:ChatPrint(("[SBJMOD] Связь создана: %s <-> %s [%s]"):format(
				sel.first:GetClass(), sel.second:GetClass(), tostring(res or "energy")))
		else
			ply:ChatPrint("[SBJMOD] Ошибка: " .. tostring(msg))
		end
		SB_JMOD.SelClear(ply)
		self:SetStage(0)
	end

	return true
end

D.Reload = function(self, tr)
	if not SERVER then return true end
	local ply = self:GetOwner()
	if not IsValid(ply) then return true end
	local ent = (tr and IsValid(tr.Entity)) and tr.Entity or nil

	if IsValid(ent) and SB_JMOD.Identify(ent) then
		local n = SB_JMOD.RemoveLinks(ent)
		if n > 0 then
			ply:ChatPrint(("[SBJMOD] Убрано связей: %d (%s)."):format(n, ent:GetClass()))
			return true
		end
		SB_JMOD.SelClear(ply)
		self:SetStage(0)
		ply:ChatPrint("[SBJMOD] У " .. ent:GetClass() .. " нет связей. Выбор сброшен.")
		return true
	end

	SB_JMOD.SelClear(ply)
	self:SetStage(0)
	ply:ChatPrint("[SBJMOD] Выбор сброшен.")
	return true
end

D.BuildCPanel = function(CPanel)
	-- Единая тёмная тема с вкладкой SBJLink
	local C_CARD   = Color(32, 36, 56, 255)
	local C_ACCENT = Color(86, 134, 255, 255)
	local C_TEXT   = Color(232, 236, 250, 255)
	local C_DIM    = Color(150, 158, 190, 255)
	local C_BORDER = Color(64, 74, 110, 160)

	local cvLinks = GetConVar(TOOL_MODE .. "_hud_links")
	local cvResHud = GetConVar("sb_jmodlink_hud_res")
	local cvRes = CreateClientConVar("sb_jmodlink_res", "auto", true, false,
		"Выбранный ресурс новых связей (auto/energy/water/...)")

	local RES_CHOICES = {
		{ "Авто (по устройству)", "auto" },
		{ "Энергия", "energy" },
		{ "Вода", "water" },
		{ "Кислород", "oxygen" },
		{ "Азот", "nitrogen" },
		{ "Водород", "hydrogen" },
		{ "Углекислый газ", "carbon dioxide" },
		{ "Пар", "steam" },
		{ "Тяжёлая вода", "heavy water" },
		{ "Жидкий азот", "liquid nitrogen" },
	}

	local function Card(tall, title, subtitle, padTop, drawFn)
		local p = vgui.Create("DPanel")
		p:SetTall(tall)
		p:DockPadding(12, padTop or 10, 12, 8)
		p.Paint = function(_, w, h)
			draw.RoundedBox(6, 0, 0, w, h, C_CARD)
			surface.SetDrawColor(C_BORDER)
			surface.DrawOutlinedRect(0, 0, w, h)
			surface.SetDrawColor(C_ACCENT)
			surface.DrawRect(10, 0, w - 20, 3)
			if title then
				draw.SimpleText(title, "DermaDefaultBold", 14, 9, C_TEXT,
					TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
			end
			if subtitle then
				draw.SimpleText(subtitle, "DermaDefault", 14, 27, C_DIM,
					TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
			end
			if drawFn then drawFn(w, h) end
		end
		return p
	end

	local function StyledButton(parent, text, base, hover, onClick)
		local b = vgui.Create("DButton", parent)
		b:SetText("")
		b:SetTall(32)
		b.hovered = false
		b.OnCursorEntered = function() b.hovered = true end
		b.OnCursorExited = function() b.hovered = false end
		b.Paint = function(_, w, h)
			draw.RoundedBox(5, 0, 0, w, h, b.hovered and hover or base)
			if b.hovered then
				surface.SetDrawColor(255, 255, 255, 40)
				surface.DrawRect(0, 0, w, 2)
			end
			draw.SimpleText(text, "DermaDefaultBold", w / 2, h / 2, color_white,
				TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		b.DoClick = onClick
		return b
	end

	CPanel:AddControl("Header", { Description = "Беспроводная перекачка ресурсов: SpaceBuild (RD3) <-> JMod. ЛКМ — быстро, ПКМ — по шагам, R — убрать связи." })

	-- Заголовок
	local head = Card(64, nil, nil, 12, function(w)
		draw.SimpleText("SB <-> JMod Link", "DermaDefaultBold", 14, 12, C_TEXT,
			TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText("v" .. tostring(SB_JMOD.Version), "DermaDefault", w - 14, 14, C_DIM,
			TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
		draw.SimpleText("энергия · вода · газы", "DermaDefault", 14, 32, C_DIM,
			TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end)
	CPanel:AddPanel(head)

	-- Статус: живой счётчик связей и выбранный ресурс
	local status = Card(52, nil, nil, 0, function(w, h)
		local n = 0
		for _, list in pairs(SB_JMOD.ClientNet or {}) do
			n = n + #list
		end
		n = math.floor(n / 2)
		draw.SimpleText("Связей: " .. n, "DermaDefaultBold", 14, 9, C_TEXT,
			TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		local res = cvRes:GetString()
		local shown = res == "auto" and "авто" or res
		draw.SimpleText("Ресурс: " .. shown, "DermaDefault", w - 14, 11, C_ACCENT,
			TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
	end)
	CPanel:AddPanel(status)

	-- Ресурс связи
	local resCard = Card(78, "Ресурс связи", nil, 30)
	local combo = vgui.Create("DComboBox", resCard)
	combo:Dock(BOTTOM)
	combo:SetTall(24)
	local current = cvRes:GetString()
	for _, pair in ipairs(RES_CHOICES) do
		combo:AddChoice(pair[1], pair[2], pair[2] == current)
	end
	combo.OnSelect = function(_, _, _, data)
		data = data or "auto"
		cvRes:SetString(data)
		RunConsoleCommand("sbjmod_res", data == "auto" and "" or data)
		status:InvalidateLayout()
	end
	CPanel:AddPanel(resCard)

	-- HUD
	local hudCard = Card(84, "HUD", nil, 30)
	local chkLinks = vgui.Create("DCheckBoxLabel", hudCard)
	chkLinks:Dock(TOP)
	chkLinks:SetText("Показывать соединения")
	chkLinks:SetTextColor(C_TEXT)
	chkLinks:SetFont("DermaDefault")
	chkLinks:SetConVar(TOOL_MODE .. "_hud_links")
	chkLinks:SetValue(cvLinks and cvLinks:GetBool() or false)

	local chkRes = vgui.Create("DCheckBoxLabel", hudCard)
	chkRes:Dock(TOP)
	chkRes:DockMargin(0, 4, 0, 0)
	chkRes:SetText("Показывать ресурсы прибора")
	chkRes:SetTextColor(C_TEXT)
	chkRes:SetFont("DermaDefault")
	chkRes:SetConVar("sb_jmodlink_hud_res")
	chkRes:SetValue(cvResHud and cvResHud:GetBool() or true)
	CPanel:AddPanel(hudCard)

	-- Кнопки
	local row = vgui.Create("DPanel")
	row:SetTall(32)
	row:DockPadding(0, 0, 0, 0)
	row.Paint = function() end
	local btnDiag = StyledButton(row, "Диагностика",
		Color(122, 86, 210, 255), Color(146, 110, 236, 255),
		function() RunConsoleCommand("sbjmod_test") end)
	btnDiag:Dock(LEFT)
	btnDiag:SetWide(120)
	local btnReset = StyledButton(row, "Сбросить выбор",
		Color(52, 92, 210, 255), Color(72, 118, 240, 255),
		function() RunConsoleCommand("sbjmod_reset") end)
	btnReset:Dock(FILL)
	btnReset:DockMargin(6, 0, 0, 0)
	CPanel:AddPanel(row)

	-- Подсказка
	local hint = vgui.Create("DPanel")
	hint:SetTall(40)
	hint:DockPadding(6, 2, 6, 6)
	hint.Paint = function(_, w, h)
		draw.SimpleText("R по устройству убирает все его связи.", "DermaDefault", 6, 2,
			C_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText("Диагностика доступна админам.", "DermaDefault", 6, 18,
			Color(120, 130, 160, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end
	CPanel:AddPanel(hint)
end

--------------------------------------------------------------------
-- ПРИМЕНЕНИЕ ОПРЕДЕЛЕНИЯ К ЗАРЕГИСТРИРОВАННОМУ ТУЛУ
--------------------------------------------------------------------
function SB_JMOD.ReloadTool()
	local gmod_tool = weapons.GetStored("gmod_tool")
	if not gmod_tool then return false, "gmod_tool не загружен" end

	gmod_tool.Tool = gmod_tool.Tool or {}
	local tool = gmod_tool.Tool[TOOL_MODE]

	if not tool then
		return false, "тул не зарегистрирован загрузчиком — нужен полный перезапуск игры"
	end

	for k, v in pairs(SB_JMOD.ToolDef) do
		tool[k] = v
	end

	tool.Objects = tool.Objects or {}
	tool.LastMessage = tool.LastMessage or 0
	tool.Stage = tool.Stage or 0
	tool.Message = tool.Message or ""

	if isfunction(tool.CreateConVars) then
		pcall(function() tool:CreateConVars() end)
	end

	list.Set("Tool", TOOL_MODE, tool)
	return true
end

if SERVER then
	AddCSLuaFile("autorun/sb_jmod_link.lua")
	util.AddNetworkString(NET_NAME)
	SB_JMOD.NetReady = true

	local cvOpenLinks = CreateConVar("sbjmod_open_links", "0",
		bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY),
		"Разрешить связывать чужие устройства всем игрокам (1) или только админам и владельцам (0)")

	----------------------------------------------------------------
	-- РЕЕСТР ОПРЕДЕЛИТЕЛЕЙ УСТРОЙСТВ
	-- Каждый модуль регистрирует свой тип один раз, по имени, с
	-- приоритетом. Повторная регистрация (хотрелоад) просто заменяет
	-- запись — обёртки над функцией не накапливаются.
	-- Чем меньше приоритет, тем раньше тип проверяется.
	----------------------------------------------------------------
	function SB_JMOD.AddIdentifier(name, priority, fn)
		if not isstring(name) or not isfunction(fn) then return false end
		SB_JMOD.Identifiers[name] = {
			priority = tonumber(priority) or 50,
			fn = fn,
		}
		SB_JMOD.IdentOrder = nil
		return true
	end

	function SB_JMOD.RemoveIdentifier(name)
		if SB_JMOD.Identifiers[name] then
			SB_JMOD.Identifiers[name] = nil
			SB_JMOD.IdentOrder = nil
			return true
		end
		return false
	end

	local function BuildOrder()
		local list = {}
		for name, d in pairs(SB_JMOD.Identifiers) do
			list[#list + 1] = { name = name, priority = d.priority, fn = d.fn }
		end
		table.sort(list, function(a, b)
			if a.priority == b.priority then return a.name < b.name end
			return a.priority < b.priority
		end)
		SB_JMOD.IdentOrder = list
		return list
	end

	-- Приоритет 40: методы самого устройства (JMod / SB).
	-- JMod-батареи и ящики методов электричества НЕ имеют: они хранят
	-- ресурс power в поле Resource (исходник: ent_jack_gmod_ezbattery.lua).
	SB_JMOD.AddIdentifier("core_methods", 40, function(e)
		local isJMod = isfunction(e.GetElectricity) and isfunction(e.SetElectricity)
		local isJModRes = e.EZsupplies == "power"
			and isfunction(e.GetResource) and isfunction(e.SetResource)
		local isSB = isfunction(e.GetResourceAmount) and isfunction(e.SetResourceAmount)
		local jmod = isJMod or isJModRes
		if jmod and isSB then return "both" end
		if jmod then return "jmod" end
		if isSB then return "sb" end
		return nil
	end)

	-- Приоритет 90: запасной вариант по префиксу класса (Life Support),
	-- если RD ещё не успел зарегистрировать устройство
	local CLASS_PREFIXES = { "storage_", "generator_", "other_", "residue_", "reactor_" }
	SB_JMOD.AddIdentifier("core_class", 90, function(e)
		local cls = e:GetClass()
		for _, pref in ipairs(CLASS_PREFIXES) do
			if string.find(cls, pref, 1, true) then return "caf" end
		end
		return nil
	end)

	-- Единая точка распознавания для всего мода.
	-- SB_JMOD.IdentifyExt оставлен для совместимости со сторонними модулями.
	function SB_JMOD.Identify(e)
		if not IsValid(e) then return nil end

		if isfunction(SB_JMOD.IdentifyExt) then
			local ok, t = pcall(SB_JMOD.IdentifyExt, e)
			if ok and t then return t end
		end

		local list = SB_JMOD.IdentOrder or BuildOrder()
		for i = 1, #list do
			local ok, t = pcall(list[i].fn, e)
			if ok and t then return t end
		end
		return nil
	end

	----------------------------------------------------------------
	-- ПРАВА НА СВЯЗИ
	----------------------------------------------------------------
	local function OwnerOf(e)
		if not IsValid(e) then return nil end
		if isfunction(e.CPPIGetOwner) then
			local ok, o = pcall(e.CPPIGetOwner, e)
			if ok and IsValid(o) and o:IsPlayer() then return o end
		end
		if isfunction(e.GetCreator) then
			local ok, o = pcall(e.GetCreator, e)
			if ok and IsValid(o) and o:IsPlayer() then return o end
		end
		return nil
	end
	SB_JMOD.OwnerOf = OwnerOf

	--- Можно ли игроку ply трогать устройство e
	function SB_JMOD.CanLink(ply, e)
		if not IsValid(e) then return false, "объект недействителен" end
		if e:IsPlayer() then return false, "игрок — не устройство" end
		if not IsValid(ply) then return true end -- серверная консоль
		if cvOpenLinks:GetBool() then return true end
		if ply:IsAdmin() then return true end

		local owner = OwnerOf(e)
		if not IsValid(owner) or owner == ply then return true end
		return false, "устройство принадлежит " .. owner:Nick()
	end

	----------------------------------------------------------------
	-- ВЫБОР И СВЯЗИ
	----------------------------------------------------------------
	function SB_JMOD.Sel(ply)
		ply.SBJMOD_Sel = ply.SBJMOD_Sel or {}
		return ply.SBJMOD_Sel
	end

	function SB_JMOD.SelClear(ply)
		if IsValid(ply) then ply.SBJMOD_Sel = {} end
	end

	function SB_JMOD.CreateLink(a, b, ply)
		if not IsValid(a) or not IsValid(b) then return false, "объект недействителен" end
		if a == b then return false, "нельзя связать объект с самим собой" end
		if not SB_JMOD.Identify(a) then return false, "первый объект — не устройство SB/JMod/CAF" end
		if not SB_JMOD.Identify(b) then return false, "второй объект — не устройство SB/JMod/CAF" end

		if IsValid(ply) then
			local okA, whyA = SB_JMOD.CanLink(ply, a)
			if not okA then return false, whyA end
			local okB, whyB = SB_JMOD.CanLink(ply, b)
			if not okB then return false, whyB end
		end

		for _, l in ipairs(SB_JMOD.Links) do
			if (l.a == a and l.b == b) or (l.a == b and l.b == a) then
				return false, "эти объекты уже связаны"
			end
		end
		local id = SB_JMOD.NextID
		SB_JMOD.NextID = id + 1

		-- Ресурс связи: energy/water/oxygen/... (transfer.lua, v9.1+)
		local res = "energy"
		if isfunction(SB_JMOD.ChooseResource) then
			local okR, r = pcall(SB_JMOD.ChooseResource, a, b, ply)
			if okR and isstring(r) then res = r end
		end

		local l = {
			id = id, a = a, b = b,
			res = res,
		}
		table.insert(SB_JMOD.Links, l)
		if isfunction(SB_JMOD.RopeCreate) then SB_JMOD.RopeCreate(l) end
		if not SB_JMOD.HotReloading then
			print(("[SBJMOD] Связь #%d: %s <-> %s [%s]"):format(
				id, a:GetClass(), b:GetClass(), res))
		end
		SB_JMOD.SyncSoon()
		return true, id, res
	end

	function SB_JMOD.RemoveLinks(e)
		local removed = 0
		for i = #SB_JMOD.Links, 1, -1 do
			local l = SB_JMOD.Links[i]
			if l.a == e or l.b == e then
				if isfunction(SB_JMOD.RopeRemove) then SB_JMOD.RopeRemove(l) end
				table.remove(SB_JMOD.Links, i)
				removed = removed + 1
			end
		end
		if removed > 0 then SB_JMOD.SyncSoon() end
		return removed
	end

	function SB_JMOD.RemoveEntity(e)
		SB_JMOD.RemoveLinks(e)
	end

	--- Убрать из таблицы связи с недействительными объектами.
	--- Вызывается таймером и после очистки карты.
	function SB_JMOD.Prune()
		local removed = 0
		for i = #SB_JMOD.Links, 1, -1 do
			local l = SB_JMOD.Links[i]
			if not IsValid(l.a) or not IsValid(l.b) then
				if isfunction(SB_JMOD.RopeRemove) then SB_JMOD.RopeRemove(l) end
				table.remove(SB_JMOD.Links, i)
				removed = removed + 1
			end
		end
		if removed > 0 then SB_JMOD.SyncSoon() end
		return removed
	end

	hook.Add("EntityRemoved", "SBJMOD_Cleanup", function(e)
		SB_JMOD.RemoveEntity(e)
	end)

	hook.Add("PostCleanupMap", "SBJMOD_CleanupMap", function()
		for i = #SB_JMOD.Links, 1, -1 do
			local l = SB_JMOD.Links[i]
			if not IsValid(l.a) or not IsValid(l.b) then
				table.remove(SB_JMOD.Links, i)
			end
		end
		SB_JMOD.SyncSoon()
	end)

	----------------------------------------------------------------
	-- СИНХРОНИЗАЦИЯ СВЯЗЕЙ КЛИЕНТАМ
	-- Пакет уходит при изменении (dirty), при заходе игрока и раз в
	-- NET_INTERVAL, если изменения так и остались неотправленными.
	----------------------------------------------------------------
	function SB_JMOD.Sync(ply)
		if not SB_JMOD.NetReady then return end

		local n = math.min(#SB_JMOD.Links, MAX_SYNC_LINKS)
		net.Start(NET_NAME)
		net.WriteUInt(n, 16)
		for i = 1, n do
			local l = SB_JMOD.Links[i]
			net.WriteUInt(math.Clamp(l.a:EntIndex(), 0, 65535), 16)
			net.WriteUInt(math.Clamp(l.b:EntIndex(), 0, 65535), 16)
		end

		if IsValid(ply) then
			net.Send(ply)
		else
			net.Broadcast()
			SB_JMOD.SyncDirty = false
		end
	end

	function SB_JMOD.SyncSoon()
		SB_JMOD.SyncDirty = true
		timer.Create("SBJMOD_SyncOnce", 0.1, 1, function() SB_JMOD.Sync() end)
	end

	-- Страховка: если изменения не дошли (например, игрок только зашёл),
	-- раз в NET_INTERVAL отправляем актуальное состояние.
	timer.Create("SBJMOD_SyncLoop", NET_INTERVAL, 0, function()
		if not SB_JMOD.SyncDirty then return end
		SB_JMOD.Sync()
	end)

	-- Свежий клиент получает связи при заходе, а не через 5 секунд
	hook.Add("PlayerInitialSpawn", "SBJMOD_SyncJoin", function(ply)
		timer.Simple(3, function()
			if IsValid(ply) then SB_JMOD.Sync(ply) end
		end)
	end)

	-- Мёртвый таймер из версий до 9.0 (SB_JMOD.Pump никогда не существовал)
	timer.Remove("SBJMOD_Pump")
	timer.Create("SBJMOD_Cleanup", 2, 0, SB_JMOD.Prune)

	----------------------------------------------------------------
	-- РЕСУРСЫ ПРИБОРА ДЛЯ HUD
	-- Клиент спрашивает по индексу сущности, сервер отвечает списком
	-- { res, value, cap } из SB_JMOD.CollectResources (transfer.lua).
	----------------------------------------------------------------
	local NET_RESQ = "SBJMOD_ResQ"
	local NET_RESR = "SBJMOD_ResR"
	util.AddNetworkString(NET_RESQ)
	util.AddNetworkString(NET_RESR)

	net.Receive(NET_RESQ, function(_, ply)
		if not IsValid(ply) then return end
		-- Не чаще 4 запросов в секунду с игрока
		if (ply.SBJMOD_ResNext or 0) > CurTime() then return end
		ply.SBJMOD_ResNext = CurTime() + 0.25

		local e = Entity(net.ReadUInt(16))
		if not IsValid(e) then return end
		if not isfunction(SB_JMOD.CollectResources) then return end

		local list = SB_JMOD.CollectResources(e)
		if not list then return end

		local n = math.min(#list, 8)
		net.Start(NET_RESR)
		net.WriteUInt(math.Clamp(e:EntIndex(), 0, 65535), 16)
		net.WriteUInt(n, 8)
		for i = 1, n do
			local r = list[i]
			net.WriteString(tostring(r.res))
			net.WriteUInt(math.Clamp(math.floor(r.value or 0), 0, 4294967295), 32)
			net.WriteUInt(math.Clamp(math.floor(r.cap or 0), 0, 4294967295), 32)
		end
		net.Send(ply)
	end)

	----------------------------------------------------------------
	-- КОНСОЛЬНЫЕ КОМАНДЫ
	----------------------------------------------------------------
	concommand.Add("sbjmod_select", function(ply)
		if not IsValid(ply) then return end
		local e = ply:GetEyeTrace().Entity
		if not IsValid(e) then ply:ChatPrint("[SBJMOD] Под прицелом ничего.") return end
		local ok, why = SB_JMOD.CanLink(ply, e)
		if not ok then ply:ChatPrint("[SBJMOD] " .. tostring(why)) return end
		SB_JMOD.Sel(ply).first = e
		SB_JMOD.Sel(ply).second = nil
		ply:ChatPrint("[SBJMOD] Выбрано: " .. e:GetClass())
	end)

	concommand.Add("sbjmod_link", function(ply)
		if not IsValid(ply) then return end
		local sel = SB_JMOD.Sel(ply)
		if not IsValid(sel.first) then ply:ChatPrint("[SBJMOD] Сначала выполните sbjmod_select.") return end
		local e = ply:GetEyeTrace().Entity
		if not IsValid(e) then ply:ChatPrint("[SBJMOD] Под прицелом ничего.") return end
		local ok, msg = SB_JMOD.CreateLink(sel.first, e, ply)
		ply:ChatPrint(ok and ("[SBJMOD] Связь создана (#" .. tostring(msg) .. ").")
			or ("[SBJMOD] Ошибка: " .. tostring(msg)))
		if ok then SB_JMOD.SelClear(ply) end
	end)

	concommand.Add("sbjmod_reset", function(ply)
		if not IsValid(ply) then return end
		SB_JMOD.SelClear(ply)
		ply:ChatPrint("[SBJMOD] Сброшено.")
	end)

	concommand.Add("sb_jmod_dump", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end
		print("=== SB <-> JMod Link v" .. SB_JMOD.Version .. ": связи ===")
		if #SB_JMOD.Links == 0 then print("(нет связей)") return end
		for _, l in ipairs(SB_JMOD.Links) do
			local ka = SB_JMOD.Identify(l.a) or "?"
			local kb = SB_JMOD.Identify(l.b) or "?"
			print(("#%d: %s [%s] <-> %s [%s], ресурс %s (беспроводная связь)"):format(
				l.id, l.a:GetClass(), ka, l.b:GetClass(), kb, l.res or "energy"))
		end
	end)

	-- ВАЖНО: команда sbjmod_reload здесь НЕ регистрируется.
	-- Перезагрузкой занимается только sb_jmod_hotreload.lua (умная,
	-- с сетевым обновлением клиентов). Две команды с одним именем
	-- перезаписывали друг друга в зависимости от порядка загрузки
	-- файлов autorun — отсюда путаница и дубль сообщений.

	-- Стартовый print молчит во время горячей перезагрузки
	-- (иначе на listen-сервере видно дважды: сервер + клиент)
	if not SB_JMOD.HotReloading then
		print("[SBJMOD] Ядро SB <-> JMod Link v" .. SB_JMOD.Version .. " загружено (server)")
	end

	-- Загрузка модулей (отсутствие файла не роняет ядро)
	local modules = { "transfer", "rope", "caf", "autolink", "jmodlegacy", "fusion" }
	for _, m in ipairs(modules) do
		local ok, err = pcall(include, "sb_jmod/" .. m .. ".lua")
		if not ok then
			print("[SBJMOD] Модуль " .. m .. " ОШИБКА: " .. tostring(err))
		end
	end
end

if CLIENT then
	SB_JMOD.ClientLinks = SB_JMOD.ClientLinks or {}
	SB_JMOD.ClientNet = SB_JMOD.ClientNet or {}

	-- Показ надписи «Соединено:» при наведении. По умолчанию ВЫКЛЮЧЕНА.
	CreateClientConVar("sb_jmodlink_hud_links", "0", true, false,
		"Показывать соединения при наведении на устройство (0/1)")

	-- Показ ресурсов прибора под прицелом (энергия/вода/кислород/...).
	CreateClientConVar("sb_jmodlink_hud_res", "1", true, false,
		"Показывать ресурсы устройства под прицелом (0/1)")

	surface.CreateFont("SBJMOD_LinkHUD", {
		font = "Tahoma",
		size = 22,
		weight = 700,
		antialias = true,
	})

	surface.CreateFont("SBJMOD_LinkHUDSmall", {
		font = "Tahoma",
		size = 18,
		weight = 700,
		antialias = true,
	})

	-- Приём связей от сервера: строим таблицу «устройство -> список партнёров»
	net.Receive(NET_NAME, function()
		local n = net.ReadUInt(16)
		local adj = {}
		for i = 1, n do
			local ai = net.ReadUInt(16)
			local bi = net.ReadUInt(16)
			adj[ai] = adj[ai] or {}
			table.insert(adj[ai], bi)
			adj[bi] = adj[bi] or {}
			table.insert(adj[bi], ai)
		end
		SB_JMOD.ClientNet = adj
	end)

	-- Убираем старые лучи, если остались от прошлых версий
	hook.Remove("PostDrawTranslucentRenderables", "SBJMOD_Beams")
	hook.Remove("PostDrawOpaqueRenderables", "SBJMOD_Beams")

	-- Красивое имя класса: убираем технические префиксы
	local function PrettifyClass(cls)
		cls = cls:gsub("^ent_jack_gmod_", ""):gsub("^gmod_", "")
		cls = cls:gsub("^storage_", ""):gsub("^generator_", "")
		cls = cls:gsub("^other_", ""):gsub("^residue_", ""):gsub("^reactor_", "")
		return cls:sub(1, 1):upper() .. cls:sub(2)
	end

	-- Кэш ресурсов прибора, полученных с сервера (по индексу сущности)
	SB_JMOD.ResCache = SB_JMOD.ResCache or {}
	local NET_RESQ = "SBJMOD_ResQ"
	local NET_RESR = "SBJMOD_ResR"
	local nextResQ = 0

	net.Receive(NET_RESR, function()
		local idx = net.ReadUInt(16)
		local n = net.ReadUInt(8)
		local list = {}
		for i = 1, n do
			list[i] = {
				res = net.ReadString(),
				value = net.ReadUInt(32),
				cap = net.ReadUInt(32),
			}
		end
		SB_JMOD.ResCache[idx] = { time = CurTime(), list = list }
	end)

	local function ResourceLabel(res)
		local s = tostring(res)
		return s:sub(1, 1):upper() .. s:sub(2)
	end

	-- HUD при наведении: связи (sb_jmodlink_hud_links) и ресурсы прибора
	-- (sb_jmodlink_hud_res). Тумблеры независимы друг от друга.
	hook.Add("HUDPaint", "SBJMOD_LinkHUD", function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local e = ply:GetEyeTrace().Entity
		if not IsValid(e) then return end

		local cvLinks = GetConVar("sb_jmodlink_hud_links")
		local cvRes = GetConVar("sb_jmodlink_hud_res")
		local showLinks = cvLinks and cvLinks:GetBool()
		local showRes = cvRes and cvRes:GetBool()
		if not showLinks and not showRes then return end

		local pos = e:LocalToWorld(e:OBBCenter()):ToScreen()
		if not pos.visible then return end

		-- Запрос ресурсов не чаще раза в 0,4 с (сервер тоже режет частоту)
		if showRes and CurTime() >= nextResQ then
			nextResQ = CurTime() + 0.4
			net.Start(NET_RESQ)
			net.WriteUInt(math.Clamp(e:EntIndex(), 0, 65535), 16)
			net.SendToServer()
		end

		local y = pos.y

		if showLinks then
			local partners = SB_JMOD.ClientNet[e:EntIndex()]
			if partners and #partners > 0 then
				local counts, order = {}, {}
				for _, idx in ipairs(partners) do
					local p = Entity(idx)
					if IsValid(p) then
						local name = PrettifyClass(p:GetClass())
						if not counts[name] then
							counts[name] = 0
							table.insert(order, name)
						end
						counts[name] = counts[name] + 1
					end
				end

				if #order > 0 then
					local parts = {}
					for _, name in ipairs(order) do
						table.insert(parts, name .. " (" .. counts[name] .. ")")
					end
					draw.SimpleText("Соединено:", "SBJMOD_LinkHUDSmall", pos.x, y - 26,
						Color(120, 220, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					draw.SimpleText(table.concat(parts, " - "), "SBJMOD_LinkHUD", pos.x, y,
						Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
					y = y + 16
				end
			end
		end

		if showRes then
			local cached = SB_JMOD.ResCache[e:EntIndex()]
			if cached and (CurTime() - cached.time) < 2 then
				for i, r in ipairs(cached.list) do
					local text = ResourceLabel(r.res) .. ": " .. r.value .. " / " .. r.cap
					draw.SimpleText(text, "SBJMOD_LinkHUDSmall", pos.x, y + (i - 1) * 18,
						Color(190, 235, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				end
			end
		end
	end)

	-- Ручной резерв: горячая перезагрузка по сети обновляет клиентов
	-- автоматически, эта команда — на случай, если сеть недоступна
	concommand.Add("sbjmod_reload_cl", function()
		local ok, err = pcall(include, "autorun/sb_jmod_link.lua")
		print(ok and "[SBJMOD] Клиент: ядро OK"
			or ("[SBJMOD] Клиент: ядро ОШИБКА: " .. tostring(err)))

		local okT, errT = SB_JMOD.ReloadTool()
		print(okT and "[SBJMOD] Клиент: тул OK — закройте меню и возьмите тулган заново."
			or ("[SBJMOD] Клиент: тул ОШИБКА: " .. tostring(errT)))
	end)

	-- Стартовый print молчит во время горячей перезагрузки
	if not SB_JMOD.HotReloading then
		print("[SBJMOD] Ядро SB <-> JMod Link v" .. SB_JMOD.Version .. " загружено (client)")
	end
end
