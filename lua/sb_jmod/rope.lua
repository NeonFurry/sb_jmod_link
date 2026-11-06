
local MATERIAL = "cable/cable2"
local WIDTH = 2
local MIN_STEP = 8          -- Ð¿Ð¾ÑÐ¾Ð³ Ð¾Ð±Ð½Ð¾Ð²Ð»ÐµÐ½Ð¸Ñ Ð´Ð»Ð¸Ð½Ñ, ÐµÐ´.
local UPDATE_INTERVAL = 0.2 -- ÐºÐ°Ðº ÑÐ°ÑÑÐ¾ Ð¿ÐµÑÐµÑÑÐ¸ÑÑÐ²Ð°ÐµÐ¼ Ð´Ð»Ð¸Ð½Ñ, ÑÐµÐº.

-- Ð¢Ð¾ÑÐºÐ° ÐºÑÐµÐ¿Ð»ÐµÐ½Ð¸Ñ: ÑÐµÐ½ÑÑ ÑÐ½ÑÐ¸ÑÐ¸
local function WPos(e)
	if not IsValid(e) then return nil end
	local ok, pos = pcall(e.LocalToWorld, e, e:OBBCenter())
	if ok then return pos end
	return e:GetPos()
end

function SB_JMOD.RopeRemove(l)
	if IsValid(l.cons) then l.cons:Remove() end
	if IsValid(l.ropeVis) then l.ropeVis:Remove() end
	l.cons, l.ropeVis, l.ropeLen, l.ropeLenBase = nil, nil, nil, nil
end

function SB_JMOD.RopeCreate(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end
	if l.norope then return end -- Ð»ÑÑ Ð²Ð¼ÐµÑÑÐ¾ ÑÐ¸Ð·Ð¸ÑÐµÑÐºÐ¾Ð³Ð¾ ÑÑÐ¾ÑÐ°
	SB_JMOD.RopeRemove(l)

	local pa, pb = WPos(l.a), WPos(l.b)
	if not pa or not pb then return end

	local dist = pa:Distance(pb)
	local len = math.max(dist, 1)

	-- Ð½ÐµÑÐ²ÐµÑÑÑÐ¸Ð¹ÑÑ ÑÑÐ¾Ñ, Ð´Ð»Ð¸Ð½Ð° = ÑÐ°ÑÑÑÐ¾ÑÐ½Ð¸Ðµ
	local cons, ropeVis = constraint.Rope(
		l.a, l.b, 0, 0,
		vector_origin, vector_origin,
		len, 0,
		0,              -- forceLimit: 0 = Ð½Ðµ ÑÐ²ÑÑÑÑ
		WIDTH, MATERIAL, false)

	if not IsValid(cons) then
		print("[SBJMOD][rope] ÐÐµ ÑÐ´Ð°Ð»Ð¾ÑÑ ÑÐ¾Ð·Ð´Ð°ÑÑ ÑÑÐ¾Ñ Ð´Ð»Ñ ÑÐ²ÑÐ·Ð¸ #" .. tostring(l.id))
		SB_JMOD.RopeRemove(l)
		return
	end

	l.cons = cons
	l.ropeVis = ropeVis
	l.ropeLenBase = len

	-- ÑÑÐ°Ð·Ñ Ð´Ð¾Ð±Ð°Ð²Ð»ÑÐµÐ¼ Ð¿ÑÐ¾Ð²Ð¸Ñ, ÑÑÐ¾Ð±Ñ ÑÑÐ¾Ñ Ð½Ðµ Ð²ÑÐ³Ð»ÑÐ´ÐµÐ» ÐºÐ°Ðº Ð¿ÑÑÐ¶Ð¸Ð½Ð°
	local sag = math.max(l.sag or 10, 0)
	l.ropeLen = len + sag
	cons:SetKeyValue("addlength", sag)
end

-- ÐÐ¾Ð»Ð¸Ð²Ð°Ð½Ð¸Ðµ/ÑÐ¾ÑÐºÐ°Ð½Ð¸Ð²Ð°Ð½Ð¸Ðµ Ð´Ð»Ð¸Ð½Ñ: Ð²ÑÐ·ÑÐ²Ð°ÐµÑÑÑ ÑÐ´ÑÐ¾Ð¼ Ð¸Ð· Ð¿Ð¾Ð¼Ð¿Ñ (1 ÑÐ°Ð·/ÑÐµÐº)
-- Ð¸ Ð¸Ð· Ð½Ð°ÑÐµÐ³Ð¾ Ð±ÑÑÑÑÐ¾Ð³Ð¾ ÑÐ°Ð¹Ð¼ÐµÑÐ° Ð½Ð¸Ð¶Ðµ (0.2 ÑÐµÐº)
function SB_JMOD.RopeEnsure(l)
	if l.norope then return end
	local cons = l.cons
	if not IsValid(cons) or not IsValid(l.a) or not IsValid(l.b) then return end

	local pa, pb = WPos(l.a), WPos(l.b)
	if not pa or not pb then return end

	local dist = pa:Distance(pb)
	if math.abs(dist - (l.ropeLen or 0)) < MIN_STEP then return end

	local want = math.max(dist + math.max(l.sag or 10, 0), 1)
	cons:SetKeyValue("addlength", want - (l.ropeLenBase or want))
	l.ropeLen = want
end

-- ÐÑÑÑÑÑÐ¹ ÑÐ¸ÐºÐ» Ð¿Ð¾Ð´Ð´ÐµÑÐ¶ÐºÐ¸ Ð´Ð»Ð¸Ð½Ñ â ÑÑÐ¾ ÑÐ¾, ÑÑÐ¾ Ð´ÐµÐ»Ð°ÐµÑ ÑÑÐ¾Ñ Ð¿Ð»Ð°Ð²Ð½ÑÐ¼
timer.Create("SBJMOD_RopeDyn", UPDATE_INTERVAL, 0, function()
	if not SB_JMOD.Links then return end
	for _, l in ipairs(SB_JMOD.Links) do
		SB_JMOD.RopeEnsure(l)
	end
end)

print("[SBJMOD] ÐÐ¾Ð´ÑÐ»Ñ rope Ð·Ð°Ð³ÑÑÐ¶ÐµÐ½: Ð´Ð¸Ð½Ð°Ð¼Ð¸ÑÐµÑÐºÐ°Ñ Ð´Ð»Ð¸Ð½Ð° ÑÑÐ¾ÑÐ° Ð²ÐºÐ»ÑÑÐµÐ½Ð°")
