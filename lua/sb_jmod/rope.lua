--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Rope (v2)
	Динамический физический трос: бесконечно растягивается и сам
	стягивается. ВАЖНО: длина верёвки меняется только пересозданием
	констрейнта — SetKeyValue("addlength") после спавна энтити движком
	игнорируется, поэтому старый подход не мог работать в принципе.
--------------------------------------------------------------------]]

local MATERIAL = "cable/cable2"
local WIDTH = 2
local DEFAULT_SAG = 10      -- провис по умолчанию, ед.
local CHANGE_EPS = 8        -- пересоздаём трос, если длина разошлась с расстоянием больше чем на это
local UPDATE_INTERVAL = 0.1 -- не чаще, чем раз в столько секунд на одну связь

local function WPos(e)
	if not IsValid(e) then return nil end
	local ok, pos = pcall(e.LocalToWorld, e, e:OBBCenter())
	if ok then return pos end
	return e:GetPos()
end

-- Убирает старый трос связи
function SB_JMOD.RopeRemove(l)
	if IsValid(l.cons) then l.cons:Remove() end
	if IsValid(l.ropeVis) then l.ropeVis:Remove() end
	l.cons, l.ropeVis, l.ropeLen = nil, nil, nil
end

-- Пересоздание верёвки с новой длиной (возвращает true, если удалось)
local function BuildRope(l, len)
	if not IsValid(l.a) or not IsValid(l.b) then return false end
	SB_JMOD.RopeRemove(l)

	local cons, ropeVis = constraint.Rope(
		l.a, l.b, 0, 0,
		vector_origin, vector_origin,
		len, 0,
		0,              -- forceLimit: 0 = не рвётся
		WIDTH, MATERIAL, false)

	if not IsValid(cons) then
		print("[SBJMOD][rope] Не удалось создать трос для связи #" .. tostring(l.id))
		return false
	end

	l.cons, l.ropeVis, l.ropeLen = cons, ropeVis, len
	return true
end

-- Создание троса для связи (вызывается ядром при создании связи)
function SB_JMOD.RopeCreate(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end
	if l.norope then return end -- луч вместо физического троса

	local pa, pb = WPos(l.a), WPos(l.b)
	if not pa or not pb then return end

	local dist = pa:Distance(pb)
	local sag = math.max(l.sag or DEFAULT_SAG, 0)
	local len = math.max(dist + sag, 1) -- сразу с провисом, чтобы не была натянута

	if not BuildRope(l, len) then
		l.norope = true -- физика недоступна —fallback на лазерный луч
	end
end

-- Подгонка длины: если реальное расстояние разошлось с длиной троса —
-- пересоздаём верёвку с новой длиной (не чаще UPDATE_INTERVAL на связь).
-- Новая длина всегда >= расстояния + провис, поэтому констрейнт не тянет.
function SB_JMOD.RopeEnsure(l)
	if l.norope then return end
	if not IsValid(l.a) or not IsValid(l.b) then return end

	local pa, pb = WPos(l.a), WPos(l.b)
	if not pa or not pb then return end

	local dist = pa:Distance(pb)
	local sag = math.max(l.sag or DEFAULT_SAG, 0)
	local want = math.max(dist + sag, 1)
	local cur = l.ropeLen or want

	if math.abs(want - cur) <= CHANGE_EPS then return end

	local now = CurTime()
	if now - (l.lastRopeRebuild or 0) < UPDATE_INTERVAL then return end
	l.lastRopeRebuild = now

	BuildRope(l, want)
end

-- Каждый тик следим за длиной — с пересозданием это уже не дорогое обновление,
-- но и не необходимое каждый тик: проверка дистанции лёгкая
hook.Add("Think", "SBJMOD_RopeDyn", function()
	if not SB_JMOD.Links then return end
	for _, l in ipairs(SB_JMOD.Links) do
		SB_JMOD.RopeEnsure(l)
	end
end)

print("[SBJMOD] Модуль rope v2 загружен: пересоздание верёвки для динамической длины")
