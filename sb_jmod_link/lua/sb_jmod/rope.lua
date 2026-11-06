--[[
	SB <-> JMod Link — физический трос (сервер).
]]

SB_JMOD.RopeLoaded = true

function SB_JMOD.RopeCreate(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end
	if l.norope then return end
	if IsValid(l.rope) then return end
	local dist = l.a:GetPos():Distance(l.b:GetPos())
	local ok, rop = pcall(constraint.Rope,
		l.a, l.b,
		0, 0,
		Vector(0, 0, 0), Vector(0, 0, 0),
		dist + (l.sag or 10),
		0,
		0,
		2,
		"cable/cable2",
		false)
	if ok and rop then
		l.rope = rop
	end
end

function SB_JMOD.RopeRemove(l)
	if IsValid(l.rope) then
		pcall(function() l.rope:Remove() end)
	end
	l.rope = nil
end

function SB_JMOD.RopeEnsure(l)
	if l.norope then return end
	if not IsValid(l.rope) then SB_JMOD.RopeCreate(l) end
end
