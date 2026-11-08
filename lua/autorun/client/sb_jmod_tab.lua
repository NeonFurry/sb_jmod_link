--[[--------------------------------------------------------------------
	SB <-> JMod Link — Spawnmenu-вкладка «SBJLink» (клиент)
	Своя верхняя вкладка рядом с Tool / Utilities / Options
	(spawnmenu.AddToolTab). Содержит:
	  - кнопку взятия тула SB <-> JMod Link;
	  - меню Fusion Generator: лимит энергии, ёмкость бака воды,
	    бесконечная вода, без повреждений;
	  - кнопки диагностики и обновления значений.

	Настройки живут в СЕРВЕРНЫХ конварах sbjmod_fusion_* (fusion.lua).
	Клиентские зеркала sb_jmodlink_* — только для привязки слайдеров.

	Формат net (совпадает с fusion.lua v2.0):
	  SBJMOD_FusionSet (серв->кл): UInt32 energy, UInt32 water, Bit inf, Bit nodmg
	  SBJMOD_FusionCmd (кл->серв): Bit apply; при apply=1 дальше
	                               UInt32 energy, UInt32 water, Bit inf, Bit nodmg
--------------------------------------------------------------------]]

if SERVER then return end

SB_JMOD = SB_JMOD or {}

--------------------------------------------------------------------
-- Клиентские зеркала (привязка слайдеров/чекбоксов).
-- На сервер уходит net-сообщение; сервер валидирует и рассылает
-- обратно — единый источник истины всегда сервер.
--------------------------------------------------------------------
CreateClientConVar("sb_jmodlink_energy_limit", "0", false, false,
	"Лимит энергии Fusion Generators, 0 = как в моде")
CreateClientConVar("sb_jmodlink_water_limit", "0", false, false,
	"Ёмкость бака воды Fusion Generators, 0 = как в моде")
CreateClientConVar("sb_jmodlink_infinite_water", "0", false, false,
	"Бесконечная вода в Fusion Generators (0/1)")
CreateClientConVar("sb_jmodlink_no_damage", "0", false, false,
	"Fusion Generators без повреждений (0/1)")

SB_JMOD.FusionSynced = false
SB_JMOD.FusionSent = {}

local CVars = {
	energy = "sb_jmodlink_energy_limit",
	water  = "sb_jmodlink_water_limit",
	inf    = "sb_jmodlink_infinite_water",
	nodmg  = "sb_jmodlink_no_damage",
}

local function CV(name) return GetConVar(CVars[name]) end

local function ReadAll()
	return {
		energy = math.Clamp(math.floor(CV("energy"):GetFloat()), 0, 100000000),
		water  = math.Clamp(math.floor(CV("water"):GetFloat()), 0, 100000000),
		inf    = CV("inf"):GetBool(),
		nodmg  = CV("nodmg"):GetBool(),
	}
end

local function SendAsk()
	if not LocalPlayer():IsValid() then return end
	net.Start("SBJMOD_FusionCmd")
	net.WriteBit(0)
	net.SendToServer()
end

local function SendApply(v)
	if not LocalPlayer():IsValid() then return end
	net.Start("SBJMOD_FusionCmd")
	net.WriteBit(1)
	net.WriteUInt(v.energy, 32)
	net.WriteUInt(v.water, 32)
	net.WriteBit(v.inf and 1 or 0)
	net.WriteBit(v.nodmg and 1 or 0)
	net.SendToServer()
end

--------------------------------------------------------------------
-- Синхронизация
--------------------------------------------------------------------
net.Receive("SBJMOD_FusionSet", function()
	local v = {
		energy = net.ReadUInt(32),
		water  = net.ReadUInt(32),
		inf    = net.ReadBit() == 1,
		nodmg  = net.ReadBit() == 1,
	}
	SB_JMOD.FusionSynced = true
	SB_JMOD.FusionSent = v
	timer.Remove("SBJMOD_FusionAsk")

	local function set(name, val)
		local cv = CV(name)
		if cv and cv:GetInt() ~= val then cv:SetInt(val) end
	end
	set("energy", v.energy)
	set("water", v.water)
	set("inf", v.inf and 1 or 0)
	set("nodmg", v.nodmg and 1 or 0)
end)

-- При заходе на сервер сбрасываем синхронизацию, чтобы не отправить
-- серверу значения от прошлого сервера
hook.Add("InitPostEntity", "SBJMOD_FusionReset", function()
	SB_JMOD.FusionSynced = false
	SB_JMOD.FusionSent = {}
end)

local function TryAsk()
	if SB_JMOD.FusionSynced then return end
	SendAsk()
end

-- Если значения так и не пришли (сервер перезагрузили, мы зашли
-- раньше мода) — периодически просим, пока не получим
timer.Create("SBJMOD_FusionAsk", 3, 10, TryAsk)

-- Фоновая отправка: раз в 0,3 с, только если значения изменились
local nextPush = 0
hook.Add("Think", "SBJMOD_FusionPush", function()
	if not SB_JMOD.FusionSynced then return end
	if CurTime() < nextPush then return end
	nextPush = CurTime() + 0.3

	local v = ReadAll()
	local s = SB_JMOD.FusionSent
	if s.energy == v.energy and s.water == v.water
		and s.inf == v.inf and s.nodmg == v.nodmg then return end

	SB_JMOD.FusionSent = v
	SendApply(v)
end)

--------------------------------------------------------------------
-- Modern UI Theme
-- Правила безопасности:
--   1. Никаких SetPaintedManually — дочерние панели должны рисоваться.
--   2. Paint всегда function(_, w, h) — w и h гарантированно числа.
--   3. Только документированные методы и константы (TEXT_ALIGN_*).
--   4. Текст с обводкой — только draw.SimpleTextOutlined, один источник.
--   5. Никаких AddItem на DPanel — он есть только у DForm.
--   6. Высота карточек — SizeToChildren по содержимому, не константа.
--      Ширина — всегда Dock: панель тянется и сжимается при ресайзе.
--------------------------------------------------------------------
local THEME = {
	bgMain     = Color(22, 24, 38, 255),
	bgCard     = Color(32, 36, 56, 255),

	accent     = Color(86, 134, 255, 255),

	textMain   = Color(232, 236, 250, 255),
	textDim    = Color(150, 158, 190, 255),
	textMuted  = Color(100, 110, 145, 255),

	warn       = Color(255, 116, 116, 255),
	warnOutline = Color(120, 0, 0, 255),

	btnBlue    = Color(52, 92, 210, 255),
	btnBlueH   = Color(72, 118, 240, 255),
	btnGreen   = Color(44, 150, 104, 255),
	btnGreenH  = Color(58, 178, 126, 255),
	btnPurple  = Color(122, 86, 210, 255),
	btnPurpleH = Color(146, 110, 236, 255),

	border     = Color(64, 74, 110, 140),
}

-- Строка текста с обводкой; панель создаётся сразу с родителем
local function OutlinedLabel(text, font, textColor, outlineColor, tall, parent)
	local pnl = vgui.Create("DPanel", parent)
	pnl:SetTall(tall or 24)
	pnl.Paint = function(_, w, h)
		draw.SimpleTextOutlined(
			text, font, 0, h / 2,
			textColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER,
			1, outlineColor)
	end
	return pnl
end

-- Подложка-«карточка» с акцентной полосой и заголовком
-- Высоту карточки вычисляет PerformLayout -> SizeToChildren:
-- карточка растёт/сжимается вместе с содержимым и при ресайзе.
local function StyleCard(pnl, title, subtitle, padTop)
	padTop = padTop or 12
	pnl:DockPadding(12, padTop, 12, 0)
	pnl.PerformLayout = function(self)
		self:SizeToChildren(false, true)
	end
	pnl.Paint = function(_, w, h)
		draw.RoundedBox(6, 0, 0, w, h, THEME.bgCard)
		surface.SetDrawColor(THEME.accent)
		surface.DrawRect(10, 0, w - 20, 3)
		if title then
			draw.SimpleText(title, "DermaDefaultBold", 14, 12,
				THEME.textMain, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end
		if subtitle then
			draw.SimpleText(subtitle, "DermaDefault", 14, title and 32 or 12,
				THEME.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		end
	end
end

-- Кнопка в стиле темы
local function ModernButton(text, baseColor, hoverColor)
	local btn = vgui.Create("DButton")
	btn:SetText("")
	btn:SetTall(36)

	btn.OnCursorEntered = function() btn.hovered = true end
	btn.OnCursorExited  = function() btn.hovered = false end

	btn.Paint = function(_, w, h)
		draw.RoundedBox(5, 0, 0, w, h, btn.hovered and hoverColor or baseColor)
		if btn.hovered then
			surface.SetDrawColor(255, 255, 255, 40)
			surface.DrawRect(0, 0, w, 2)
		end
		draw.SimpleText(text, "DermaDefaultBold", w / 2, h / 2,
			color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	return btn
end

--------------------------------------------------------------------
-- Построение содержимого вкладки
--------------------------------------------------------------------
local function BuildContent(CPanel)

	-- Фон всей страницы: тянется на всю панель при любом ресайзе
	CPanel.Paint = function(_, w, h)
		surface.SetDrawColor(THEME.bgMain)
		surface.DrawRect(0, 0, w, h)
		surface.SetDrawColor(THEME.accent)
		surface.DrawRect(0, 0, w, 4)
	end

	-- Тёмный фон и у зоны прокрутки, чтобы внизу не было белой пустоты
	local okC, canvas = pcall(CPanel.GetCanvas, CPanel)
	if okC and IsValid(canvas) then
		canvas.Paint = function(_, w, h)
			surface.SetDrawColor(THEME.bgMain)
			surface.DrawRect(0, 0, w, h)
		end
	end

	----------------------------------------------------------------
	-- Заголовок страницы (с отступами от верха и краёв панели)
	----------------------------------------------------------------
	local header = vgui.Create("DPanel")
	header:SetTall(64)
	header:DockPadding(16, 10, 16, 10)
	header:DockMargin(8, 6, 8, 0) -- отступ сверху и по бокам
	header.Paint = function(_, w, h)
		draw.RoundedBox(6, 0, 0, w, h, THEME.bgCard)
		surface.SetDrawColor(THEME.accent)
		surface.DrawRect(12, 0, w - 24, 3)
		draw.SimpleText("SB <-> JMod Link", "DermaDefaultBold", 16, 12,
			THEME.textMain, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText("Manage your mod settings", "DermaDefault", 16, 34,
			THEME.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end
	CPanel:AddPanel(header)

	----------------------------------------------------------------
	-- Кнопка взятия инструмента (кнопка снизу — не перекрывает текст)
	----------------------------------------------------------------
	local toolCard = vgui.Create("DPanel")
	toolCard:SetTall(88)
	toolCard:DockPadding(12, 8, 12, 8)
	toolCard:DockMargin(8, 6, 8, 0)
	toolCard.Paint = function(_, w, h)
		draw.RoundedBox(6, 0, 0, w, h, THEME.bgCard)
		surface.SetDrawColor(THEME.border)
		surface.DrawOutlinedRect(0, 0, w, h)
		draw.SimpleText("SB <-> JMod Link Tool", "DermaDefaultBold", 14, 8,
			THEME.textMain, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
		draw.SimpleText("Take the tool in your hands", "DermaDefault", 14, 28,
			THEME.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	end

	local btnTool = ModernButton("Take Tool", THEME.btnBlue, THEME.btnBlueH)
	btnTool:SetParent(toolCard)
	btnTool:Dock(BOTTOM)
	btnTool:SetTall(32)
	btnTool.DoClick = function()
		RunConsoleCommand("gmod_tool", "sb_jmodlink")
		if IsValid(g_SpawnMenu) then
			g_SpawnMenu:Close()
		end
	end
	CPanel:AddPanel(toolCard)

	----------------------------------------------------------------
	-- Подзаголовок секции
	----------------------------------------------------------------
	local intro = OutlinedLabel(
		"Server-side settings — apply to all generators on the map.",
		"DermaDefault", THEME.textDim, Color(30, 40, 70, 200), 24)
	intro:DockMargin(8, 10, 8, 10)
	CPanel:AddPanel(intro)

	----------------------------------------------------------------
	-- Fusion Generator: высота по содержимому, ширина — по родителю
	----------------------------------------------------------------
	local fp = vgui.Create("DPanel")
	StyleCard(fp, "Fusion Generator", nil, 54)
	fp:DockMargin(8, 0, 8, 0)
	CPanel:AddPanel(fp)

	-- Лимит энергии
	local sldE = fp:Add("DNumSlider")
	sldE:Dock(TOP)
	sldE:SetTall(40)
	sldE:SetText("Energy limit (0 = stock)")
	sldE:SetMin(0)
	sldE:SetMax(1000000)
	sldE:SetDecimals(0)
	sldE:SetConVar(CVars.energy)
	if IsValid(sldE.Label) then sldE.Label:SetTextColor(THEME.textMain) end

	-- Предупреждение об опасности (критический режим >= 100000)
	-- Панель создаётся сразу с родителем fp, AddItem не нужен
	local warnPanel = OutlinedLabel(
		"WARNING: energy >= 100000 goes critical (nuke on destroy).",
		"DermaDefaultBold", THEME.warn, THEME.warnOutline, 24, fp)
	warnPanel:Dock(TOP)
	warnPanel:DockMargin(0, 4, 0, 0)
	warnPanel:SetVisible(CV("energy"):GetInt() == 0
		or CV("energy"):GetInt() >= 100000)

	local function UpdateWarn(val)
		warnPanel:SetVisible(val == 0 or val >= 100000)
		fp:InvalidateLayout() -- карточка пересчитает высоту без лейбла
	end
	sldE.OnValueChanged = function(_, v) UpdateWarn(math.floor(v or 0)) end

	-- Ёмкость бака воды
	local sldW = fp:Add("DNumSlider")
	sldW:Dock(TOP)
	sldW:DockMargin(0, 4, 0, 0)
	sldW:SetTall(40)
	sldW:SetText("Water tank capacity (0 = stock)")
	sldW:SetMin(0)
	sldW:SetMax(100000)
	sldW:SetDecimals(0)
	sldW:SetConVar(CVars.water)
	if IsValid(sldW.Label) then sldW.Label:SetTextColor(THEME.textMain) end

	-- Бесконечная вода
	local chkI = fp:Add("DCheckBoxLabel")
	chkI:Dock(TOP)
	chkI:DockMargin(0, 6, 0, 0)
	chkI:SetTall(24)
	chkI:SetText("Infinite water (generator never runs dry)")
	if IsValid(chkI.Label) then chkI.Label:SetTextColor(Color(120, 220, 255, 255)) end
	chkI:SetConVar(CVars.inf)

	-- Без повреждений
	-- Нижний воздух НЕ в margin галочки: SizeToChildren ненадёжно
	-- учитывает нижний margin последнего элемента, из-за чего низ
	-- карточки поджимался к галочкам и подрезал их скруглёнными углами.
	local chkD = fp:Add("DCheckBoxLabel")
	chkD:Dock(TOP)
	chkD:DockMargin(0, 4, 0, 0)
	chkD:SetTall(24)
	chkD:SetText("No damage (full immunity)")
	if IsValid(chkD.Label) then chkD.Label:SetTextColor(Color(120, 255, 160, 255)) end
	chkD:SetConVar(CVars.nodmg)

	-- Спейсер: гарантированный воздух между галочками и низом
	-- карточки. Высоту пустой панели SizeToChildren учитывает всегда,
	-- в отличие от нижнего margin последнего элемента. Хочешь больше
	-- зазора — меняй только SetTall.
	local spacer = fp:Add("DPanel")
	spacer:Dock(TOP)
	spacer:SetTall(28)
	spacer.Paint = function() end

	----------------------------------------------------------------
	-- Кнопки действий: вторая на Dock(FILL), за край не выйдет
	----------------------------------------------------------------
	local btnRow = vgui.Create("DPanel")
	btnRow:SetTall(44)
	btnRow:DockPadding(0, 4, 0, 4)
	btnRow:DockMargin(8, 12, 8, 0) -- верхний отступ от карточки с галочками
	btnRow.Paint = function() end

	local btnAsk = ModernButton("Refresh Values", THEME.btnGreen, THEME.btnGreenH)
	btnAsk:SetParent(btnRow)
	btnAsk:Dock(LEFT)
	btnAsk:SetWide(140)
	btnAsk.DoClick = function()
		SB_JMOD.FusionSynced = false
		TryAsk()
	end

	local btnScan = ModernButton("Scan Generators", THEME.btnPurple, THEME.btnPurpleH)
	btnScan:SetParent(btnRow)
	btnScan:Dock(FILL)
	btnScan:DockMargin(8, 0, 0, 0)
	btnScan.DoClick = function()
		RunConsoleCommand("sbjmod_fusion_scan")
	end
	CPanel:AddPanel(btnRow)

	----------------------------------------------------------------
	-- Футер-подсказка: красная обводка, одна строка
	----------------------------------------------------------------
	local footer = OutlinedLabel(
		"Water capacity applies to every generator on the map.",
		"DermaDefault", THEME.textMain, Color(220, 40, 40, 255), 24)
	footer:DockMargin(20, 14, 20, 14)
	CPanel:AddPanel(footer)

	-- При открытии панели просим актуальные значения
	TryAsk()
end

--------------------------------------------------------------------
-- Вкладка: вкладка + категория + опция с ControlPanel
--------------------------------------------------------------------
hook.Add("AddToolMenuTabs", "SBJMOD_Tab", function()
	spawnmenu.AddToolTab("SBJLink", "SBJLink", "icon16/link.png")
	spawnmenu.AddToolCategory("SBJLink", "sbjmod_main", "SB <-> JMod Link")
end)

hook.Add("PopulateToolMenu", "SBJMOD_Tab", function()
	spawnmenu.AddToolMenuOption("SBJLink", "sbjmod_main", "sbjmod_panel",
		"Link & Fusion Generator", "", "", function(CPanel)
			-- Страховка: ошибка построения не роняет спавнменю,
			-- а печатается одной строкой в консоль
			local ok, err = pcall(BuildContent, CPanel)
			if not ok then
				ErrorNoHalt("[SBJMOD] Вкладка: ошибка построения панели: "
					.. tostring(err) .. "\n")
			end
		end)
end)

print("[SBJMOD] Вкладка SBJLink загружена (client)")
