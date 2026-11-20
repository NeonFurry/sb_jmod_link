--[[
	FFWL — Forcefield Whitelist (адаптация под Bendable Combine Forcefield)

	Мод: prop_forcefield + prop_forcefield_field (автор bol_snaphak)
	Эта версия НЕ добавляет свой хук ShouldCollide, а расширяет метод
	ShouldCollideWith самого поля: вайтлист проверяется внутри родной логики.

	Возможности:
	 - вайтлист игроков (SteamID), редакторов, NPC-классов + штатный вайтлист команд мода;
	 - группы NPC одним выбором: Combine (HL2), Сопротивление (HL2), Xen (ксен);
	 - меню Forcefield Manager в стиле SIR: боковая навигация, поиск, секции, плитки;
	 - раздел «Сохранения»: пресеты настроек поля (включая Forcefield Type),
	   раскладки карт (позиции всех полей и эмиттеров + настройки) и сброс поля;
	 - хранение: data/ffwl/presets.json и data/ffwl/layouts.json (набор на карту);
	 - открытие: E по полю, пункт в контекстном меню, ffwl_menu, чат !ffmenu;
	 - NPC из вайтлиста проходят поле (включая обход ИИ-блокировки в зоне у поля);
	 - через поле проходят ТОЛЬКО вписанные игроки и редакторы;
	 - админ / ULX-флаг forcefield_edit / владелец поля (CPPI) дают право редактирования;
	 - диагностика: ffwl_scan, ffwl_debug.
]]

local FIELD_CLASS = "prop_forcefield_field"
local PLATFORM_CLASS = "prop_forcefield"

--------------------------------------------------------------------
-- SHARED: пресеты групп NPC
--------------------------------------------------------------------

local NPC_GROUPS = {
	combine = {
		label = "Combine (HL2)",
		classes = {
			"npc_metropolice", "npc_combine", "npc_combine_s", "npc_manhack",
			"npc_cscanner", "npc_clawscanner", "npc_stalker", "npc_strider",
			"npc_rollermine", "npc_turret_floor", "npc_turret_ceiling",
			"npc_combine_camera", "npc_combinegunship", "npc_combinedropship",
			"npc_sniper", "npc_hunter",
		},
	},
	rebels = {
		label = "Сопротивление (HL2)",
		classes = {
			"npc_citizen", "npc_alyx", "npc_barney", "npc_kleiner",
			"npc_magnusson", "npc_eli", "npc_mossman", "npc_monk",
			"npc_vortigaunt", "npc_dog",
		},
	},
	xen = {
		label = "Xen (ксен)",
		classes = {
			"npc_headcrab", "npc_headcrab_fast", "npc_headcrab_black",
			"npc_zombie", "npc_zombie_torso", "npc_fastzombie", "npc_fastzombie_torso",
			"npc_poisonzombie", "npc_zombine", "npc_antlion", "npc_antlionguard",
			"npc_antlion_worker", "npc_barnacle", "npc_crow", "npc_pigeon",
			"npc_seagull", "npc_ichthyosaur", "npc_leech",
		},
	},
}

-- Единая проверка допуска класса: личные классы поля + классы вписанных групп
local function IsClassAllowed(field, class)
	local classes = field.FFWL_NPCClasses
	if classes and classes[class] then return true end

	for groupName in pairs(field.FFWL_NPCGroups or {}) do
		local group = NPC_GROUPS[groupName]
		if group and group.classes[class] then return true end
	end

	return false
end

--------------------------------------------------------------------
-- SHARED: расширение ShouldCollideWith мода
--------------------------------------------------------------------

local function WrapShouldCollideWith(target)
	if not target or not target.ShouldCollideWith or target.FFWL_Patched then return end
	target.FFWL_Patched = true

	local original = target.ShouldCollideWith
	target.ShouldCollideWith = function(self, other)
		if not self:GetEnabled() then return original(self, other) end
		if not IsValid(other) then return original(self, other) end

		if other:IsPlayer() then
			-- Поимённый вайтлист игроков
			local players = self.FFWL_Players
			if players and players[other:SteamID()] then return false end

			-- Вписанные редакторы
			local editors = self.FFWL_Editors
			if editors and editors[other:SteamID()] then return false end

		elseif other:IsNPC() or other:IsNextBot() then
			-- Вайтлист по классам и группам (npc_vj_automaton_trooper, Combine, ...)
			if IsClassAllowed(self, other:GetClass()) then return false end
		end

		return original(self, other)
	end
end

local function TryPatchClass()
	local stored = scripted_ents.GetStored(FIELD_CLASS)
	if not (stored and stored.t) then return false end

	WrapShouldCollideWith(stored.t)
	return stored.t.FFWL_Patched or false
end

hook.Add("InitPostEntity", "FFWL_Init", function()
	local patched = TryPatchClass()
	if SERVER then
		if patched then
			print("[FFWL] Адаптация под " .. FIELD_CLASS .. " загружена")
		else
			print("[FFWL] ВНИМАНИЕ: класс " .. FIELD_CLASS .. " не найден — мод силовых полей не установлен?")
		end
	else
		print("[FFWL] Клиентская часть загружена")
	end
end)

hook.Add("OnEntityCreated", "FFWL_EntCreated", function(ent)
	if ent:GetClass() ~= FIELD_CLASS then return end
	timer.Simple(0, function()
		if not IsValid(ent) then return end

		TryPatchClass()

		-- На случай, если класс так и не нашёлся: обёртка конкретной сущности
		local stored = scripted_ents.GetStored(FIELD_CLASS)
		if not (stored and stored.t and stored.t.FFWL_Patched) then
			WrapShouldCollideWith(ent)
		end
	end)
end)

--------------------------------------------------------------------
-- SERVER: данные, net-сообщения, права, NPC-зона, сохранения
--------------------------------------------------------------------

if SERVER then
	util.AddNetworkString("ffwl_request")
	util.AddNetworkString("ffwl_data")
	util.AddNetworkString("ffwl_action")
	util.AddNetworkString("ffwl_notify")

	if ULib then
		ULib.ucl.registerAccess("forcefield_edit", {"superadmin", "admin"}, "Доступ к менеджеру силовых полей (FFWL)", "Forcefields")
	end

	local PRESET_FILE = "ffwl/presets.json"
	local LAYOUT_FILE = "ffwl/layouts.json"

	local function LoadJSON(path, default)
		if not file.Exists(path, "DATA") then return default end
		local data = file.Read(path, "DATA")
		if not data then return default end
		return util.JSONToTable(data) or default
	end

	local function SaveJSON(path, tbl)
		file.CreateDir("ffwl")
		file.Write(path, util.TableToJSON(tbl, true))
	end

	local FF_PRESETS = LoadJSON(PRESET_FILE, {})
	local FF_LAYOUTS = LoadJSON(LAYOUT_FILE, {})

	local function HasEditAccess(ply)
		if not IsValid(ply) then return false end
		if ply:IsAdmin() then return true end
		if ULib and ULib.ucl and ULib.ucl.query(ply, "forcefield_edit") then return true end
		return false
	end

	local function IsOwner(ply, ent)
		if not IsValid(ply) then return false end
		if CPPI and ent.CPPIGetOwner and ent:CPPIGetOwner() == ply then return true end
		return false
	end

	local function CanEditField(ply, ent)
		if not IsValid(ent) or ent:GetClass() ~= FIELD_CLASS then return false end
		if HasEditAccess(ply) then return true end
		return IsOwner(ply, ent)
	end

	local function Notify(ply, text)
		net.Start("ffwl_notify")
		net.WriteString(text)
		net.Send(ply)
	end

	local ACTION_LIST = {
		addplayer = "Players", removeplayer = "Players",
		addeditor = "Editors", removeeditor = "Editors",
		addnpcclass = "NPCClasses", removenpcclass = "NPCClasses",
	}

	local function GetList(ent, key)
		local list = ent["FFWL_" .. key]
		if not list then
			list = {}
			ent["FFWL_" .. key] = list
		end
		return list
	end

	-- Снимок всех списков поля (для пресетов и раскладок)
	local function SnapshotLists(ent)
		local players, editors, npcclasses, groups, teams = {}, {}, {}, {}, {}

		for sid in pairs(ent.FFWL_Players or {}) do players[#players + 1] = sid end
		for sid in pairs(ent.FFWL_Editors or {}) do editors[#editors + 1] = sid end
		for cls in pairs(ent.FFWL_NPCClasses or {}) do npcclasses[#npcclasses + 1] = cls end
		for name in pairs(ent.FFWL_NPCGroups or {}) do groups[#groups + 1] = name end

		for teamId, teamData in pairs(team.GetAllTeams()) do
			if ent:IsTeamWhitelisted(teamId) then teams[#teams + 1] = teamId end
		end

		table.sort(players)
		table.sort(editors)
		table.sort(npcclasses)
		table.sort(groups)
		table.sort(teams)

		return {
			Players = players,
			Editors = editors,
			NPCClasses = npcclasses,
			Groups = groups,
			Teams = teams,
			FieldType = ent.GetForcefieldType and ent:GetForcefieldType() or nil,
		}
	end

	-- Применение снимка: списки заменяются целиком
	local function ApplySnapshot(ent, snap)
		ent.FFWL_Players = {}
		ent.FFWL_Editors = {}
		ent.FFWL_NPCClasses = {}
		ent.FFWL_NPCGroups = {}

		for _, sid in ipairs(snap.Players or {}) do
			if type(sid) == "string" and sid ~= "" then ent.FFWL_Players[sid] = true end
		end

		for _, sid in ipairs(snap.Editors or {}) do
			if type(sid) == "string" and sid ~= "" then ent.FFWL_Editors[sid] = true end
		end

		for _, cls in ipairs(snap.NPCClasses or {}) do
			if type(cls) == "string" and cls ~= "" then ent.FFWL_NPCClasses[cls] = true end
		end

		for _, name in ipairs(snap.Groups or {}) do
			if NPC_GROUPS[name] then ent.FFWL_NPCGroups[name] = true end
		end

		for _, teamId in ipairs(snap.Teams or {}) do
			local id = tonumber(teamId)
			if id and team.Valid(id) and not ent:IsTeamWhitelisted(id) then
				pcall(function() ent:AddTeamToWhitelist(id) end)
			end
		end

		if snap.FieldType ~= nil and ent.SetForcefieldType then
			pcall(function() ent:SetForcefieldType(snap.FieldType) end)
		end

		ent:CollisionRulesChanged()
	end

	-- Снимок раскладки: позиции и углы всех полей и эмиттеров + их настройки
	local function VecToTable(v)
		return { x = v.x, y = v.y, z = v.z }
	end

	local function LayoutSnapshot()
		local fields, platforms = {}, {}

		for _, ent in ipairs(ents.FindByClass(FIELD_CLASS)) do
			fields[#fields + 1] = {
				pos = VecToTable(ent:GetPos()),
				ang = VecToTable(ent:GetAngles()),
				enabled = ent.GetEnabled and ent:GetEnabled() or nil,
				snap = SnapshotLists(ent),
			}
		end

		for _, ent in ipairs(ents.FindByClass(PLATFORM_CLASS)) do
			platforms[#platforms + 1] = {
				pos = VecToTable(ent:GetPos()),
				ang = VecToTable(ent:GetAngles()),
			}
		end

		return { fields = fields, platforms = platforms }
	end

	local function LoadLayout(layout)
		for _, ent in ipairs(ents.FindByClass(FIELD_CLASS)) do ent:Remove() end
		for _, ent in ipairs(ents.FindByClass(PLATFORM_CLASS)) do ent:Remove() end

		timer.Simple(0.1, function()
			for _, item in ipairs(layout.fields or {}) do
				local ent = ents.Create(FIELD_CLASS)
				if IsValid(ent) then
					ent:SetPos(Vector(item.pos.x, item.pos.y, item.pos.z))
					ent:SetAngles(Angle(item.ang.x, item.ang.y, item.ang.z))
					ent:Spawn()
					ent:Activate()

					if item.enabled ~= nil and ent.SetEnabled then
						pcall(function() ent:SetEnabled(item.enabled) end)
					end

					ApplySnapshot(ent, item.snap or {})
				end
			end

			for _, item in ipairs(layout.platforms or {}) do
				local ent = ents.Create(PLATFORM_CLASS)
				if IsValid(ent) then
					ent:SetPos(Vector(item.pos.x, item.pos.y, item.pos.z))
					ent:SetAngles(Angle(item.ang.x, item.ang.y, item.ang.z))
					ent:Spawn()
					ent:Activate()
				end
			end

			print("[FFWL] Раскладка загружена: " .. #(layout.fields or {}) .. " полей, " .. #(layout.platforms or {}) .. " эмиттеров")
		end)
	end

	net.Receive("ffwl_action", function(len, ply)
		local ent = net.ReadEntity()
		if not CanEditField(ply, ent) then return end

		local action = net.ReadString()
		local value = net.ReadString() or ""

		-- Сохранения: пресеты, раскладки, сброс
		if action == "savepreset" then
			if value == "" then return end
			FF_PRESETS[value] = SnapshotLists(ent)
			SaveJSON(PRESET_FILE, FF_PRESETS)
			Notify(ply, "[FFWL] Пресет сохранён: " .. value)
			return
		elseif action == "applypreset" then
			local preset = FF_PRESETS[value]
			if not preset then return end
			ApplySnapshot(ent, preset)
			Notify(ply, "[FFWL] Пресет применён: " .. value)
			return
		elseif action == "removepreset" then
			if not FF_PRESETS[value] then return end
			FF_PRESETS[value] = nil
			SaveJSON(PRESET_FILE, FF_PRESETS)
			Notify(ply, "[FFWL] Пресет удалён: " .. value)
			return
		elseif action == "savelayout" then
			if not ply:IsAdmin() then return end
			if value == "" then return end
			FF_LAYOUTS[game.GetMap()] = FF_LAYOUTS[game.GetMap()] or {}
			FF_LAYOUTS[game.GetMap()][value] = LayoutSnapshot()
			SaveJSON(LAYOUT_FILE, FF_LAYOUTS)
			Notify(ply, "[FFWL] Раскладка сохранена: " .. value)
			return
		elseif action == "loadlayout" then
			if not ply:IsAdmin() then return end
			local set = FF_LAYOUTS[game.GetMap()]
			local layout = set and set[value]
			if not layout then return end
			LoadLayout(layout)
			Notify(ply, "[FFWL] Раскладка загружена: " .. value)
			return
		elseif action == "removelayout" then
			if not ply:IsAdmin() then return end
			local set = FF_LAYOUTS[game.GetMap()]
			if not (set and set[value]) then return end
			set[value] = nil
			SaveJSON(LAYOUT_FILE, FF_LAYOUTS)
			Notify(ply, "[FFWL] Раскладка удалена: " .. value)
			return
		elseif action == "resetfield" then
			ent.FFWL_Players = {}
			ent.FFWL_Editors = {}
			ent.FFWL_NPCClasses = {}
			ent.FFWL_NPCGroups = {}

			for teamId in pairs(team.GetAllTeams()) do
				pcall(function()
					if ent:IsTeamWhitelisted(teamId) then ent:RemoveTeamFromWhitelist(teamId) end
				end)
			end

			ent:CollisionRulesChanged()
			Notify(ply, "[FFWL] Поле сброшено")
			return
		end

		local listKey = ACTION_LIST[action]
		if listKey then
			if value == "" then return end

			local list = GetList(ent, listKey)

			if action:StartsWith("add") then
				if list[value] then return end
				list[value] = true
				Notify(ply, "[FFWL] Добавлено (" .. listKey .. "): " .. value)
			else
				if not list[value] then return end
				list[value] = nil
				Notify(ply, "[FFWL] Удалено (" .. listKey .. "): " .. value)
			end

			ent:CollisionRulesChanged()
			return
		end

		-- Группы NPC: добавляем/убираем пресет целиком
		if action == "addgroup" then
			if not NPC_GROUPS[value] then
				Notify(ply, "[FFWL] Неизвестная группа: " .. value)
				return
			end

			local list = GetList(ent, "NPCGroups")
			if list[value] then return end

			list[value] = true
			Notify(ply, "[FFWL] Группа добавлена: " .. NPC_GROUPS[value].label)
			ent:CollisionRulesChanged()
		elseif action == "removegroup" then
			if not NPC_GROUPS[value] then return end

			local list = GetList(ent, "NPCGroups")
			if not list[value] then return end

			list[value] = nil
			Notify(ply, "[FFWL] Группа удалена: " .. NPC_GROUPS[value].label)
			ent:CollisionRulesChanged()
		end

		if action == "addteam" then
			local teamId = tonumber(value)
			if not teamId or not team.Valid(teamId) then return end
			if ent:IsTeamWhitelisted(teamId) then return end

			ent:AddTeamToWhitelist(teamId)
			Notify(ply, "[FFWL] Команда добавлена в вайтлист")
		elseif action == "removeteam" then
			local teamId = tonumber(value)
			if not teamId or not team.Valid(teamId) then return end
			if not ent:IsTeamWhitelisted(teamId) then return end

			ent:RemoveTeamFromWhitelist(teamId)
			Notify(ply, "[FFWL] Команда удалена из вайтлиста")
		end
	end)

	net.Receive("ffwl_request", function(len, ply)
		local ent = net.ReadEntity()
		if not CanEditField(ply, ent) then return end

		local function CollectIDList(list)
			local result = {}
			for sid in pairs(list or {}) do
				local name = nil
				for _, p in ipairs(player.GetAll()) do
					if p:SteamID() == sid then
						name = p:Nick()
						break
					end
				end
				if name then
					result[#result + 1] = sid .. " — " .. name
				else
					result[#result + 1] = sid
				end
			end
			table.sort(result)
			return result
		end

		local function CollectRawIDs(list)
			local result = {}
			for sid in pairs(list or {}) do
				result[#result + 1] = sid
			end
			table.sort(result)
			return result
		end

		local teams, teamIds = {}, {}
		for teamId, teamData in pairs(team.GetAllTeams()) do
			if ent:IsTeamWhitelisted(teamId) then
				teams[#teams + 1] = teamData.Name
				teamIds[#teamIds + 1] = tostring(teamId)
			end
		end

		local groupRows = {}
		for name in pairs(ent.FFWL_NPCGroups or {}) do
			local group = NPC_GROUPS[name]
			if group then
				groupRows[#groupRows + 1] = { id = name, label = group.label }
			end
		end
		table.sort(groupRows, function(a, b) return a.label < b.label end)

		local groupLabels, groupIds = {}, {}
		for _, row in ipairs(groupRows) do
			groupLabels[#groupLabels + 1] = row.label
			groupIds[#groupIds + 1] = row.id
		end

		local npcclasses = {}
		for cls in pairs(ent.FFWL_NPCClasses or {}) do
			npcclasses[#npcclasses + 1] = cls
		end
		table.sort(npcclasses)

		-- Пресеты: имя + сводка содержимого
		local presetRows = {}
		for name, snap in pairs(FF_PRESETS) do
			presetRows[#presetRows + 1] = {
				name = name,
				players = #(snap.Players or {}),
				editors = #(snap.Editors or {}),
				groups = #(snap.Groups or {}),
				classes = #(snap.NPCClasses or {}),
				teams = #(snap.Teams or {}),
				fieldtype = snap.FieldType,
			}
		end
		table.sort(presetRows, function(a, b) return a.name < b.name end)

		-- Раскладки: только для админов, отдельный набор на карту
		local layoutRows = {}
		if ply:IsAdmin() then
			local set = FF_LAYOUTS[game.GetMap()] or {}
			for name, layout in pairs(set) do
				layoutRows[#layoutRows + 1] = {
					name = name,
					fields = #(layout.fields or {}),
					platforms = #(layout.platforms or {}),
				}
			end
			table.sort(layoutRows, function(a, b) return a.name < b.name end)
		end

		net.Start("ffwl_data")
		net.WriteEntity(ent)
		net.WriteTable({
			Players = CollectIDList(ent.FFWL_Players),
			PlayerIds = CollectRawIDs(ent.FFWL_Players),
			Editors = CollectIDList(ent.FFWL_Editors),
			EditorIds = CollectRawIDs(ent.FFWL_Editors),
			NPCClasses = npcclasses,
			Groups = groupLabels,
			GroupIds = groupIds,
			Teams = teams,
			TeamIds = teamIds,
			Presets = presetRows,
			Layouts = layoutRows,
			CanLayouts = ply:IsAdmin(),
		})
		net.Send(ply)
	end)

	-- Зона прохода для вайтлистных NPC: ИИ перестаёт видеть поле как препятствие
	local NEAR_DISTANCE = 170
	local FAR_DISTANCE = 250
	local FFWL_INFIELD = {}

	timer.Create("FFWL_NPCZone", 0.1, 0, function()
		for npc, field in pairs(FFWL_INFIELD) do
			if not IsValid(npc) then
				FFWL_INFIELD[npc] = nil
			elseif not IsValid(field) or npc:GetPos():Distance(field:GetPos()) > FAR_DISTANCE then
				FFWL_INFIELD[npc] = nil
				npc:SetCollisionGroup(npc.FFWL_OldCollisionGroup or COLLISION_GROUP_NONE)
				npc.FFWL_OldCollisionGroup = nil
			end
		end

		for _, field in ipairs(ents.FindByClass(FIELD_CLASS)) do
			local hasClasses = field.FFWL_NPCClasses and next(field.FFWL_NPCClasses) ~= nil
			local hasGroups = field.FFWL_NPCGroups and next(field.FFWL_NPCGroups) ~= nil
			if not hasClasses and not hasGroups then continue end

			for _, npc in ipairs(ents.FindInSphere(field:GetPos(), FAR_DISTANCE)) do
				if not (npc:IsNPC() or npc:IsNextBot()) then continue end
				if not IsClassAllowed(field, npc:GetClass()) then continue end
				if FFWL_INFIELD[npc] then continue end

				if npc:GetPos():Distance(field:GetPos()) <= NEAR_DISTANCE then
					FFWL_INFIELD[npc] = field
					npc.FFWL_OldCollisionGroup = npc:GetCollisionGroup()
					npc:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
				end
			end
		end
	end)

	hook.Add("PlayerDisconnected", "FFWL_CleanupEditor", function(ply)
		local sid = ply:SteamID()
		for _, field in ipairs(ents.FindByClass(FIELD_CLASS)) do
			local editors = field.FFWL_Editors
			if editors and editors[sid] then
				editors[sid] = nil
				field:CollisionRulesChanged()
			end
		end
	end)

	concommand.Add("ffwl_debug", function(ply)
		if not IsValid(ply) or not ply:IsAdmin() then return end

		local eyePos = ply:EyePos()
		local aimDir = ply:GetAimVector()
		local best, bestDist = nil, 120

		for _, ent in ipairs(ents.FindByClass(FIELD_CLASS)) do
			local center = ent:WorldSpaceCenter()
			local toCenter = center - eyePos
			local proj = toCenter:Dot(aimDir)
			if proj < 10 then continue end
			local closestPoint = eyePos + aimDir * proj
			local distance = closestPoint:Distance(center)
			if distance < bestDist then
				best, bestDist = ent, distance
			end
		end

		if not IsValid(best) then
			print("[FFWL] ffwl_debug: поле не найдено")
			return
		end

		print("=== [FFWL] Отладка поля ===")
		print("  Entity: " .. tostring(best) .. " (" .. best:GetClass() .. ")")
		print("  Enabled: " .. tostring(best:GetEnabled()))
		print("  Type: " .. tostring(best:GetForcefieldType()))

		local playerKeys = {}
		for sid in pairs(best.FFWL_Players or {}) do playerKeys[#playerKeys + 1] = sid end
		print("  Игроки (SteamID): " .. table.concat(playerKeys, ", "))

		local editorKeys = {}
		for sid in pairs(best.FFWL_Editors or {}) do editorKeys[#editorKeys + 1] = sid end
		print("  Редакторы: " .. table.concat(editorKeys, ", "))

		local groupNames = {}
		for name in pairs(best.FFWL_NPCGroups or {}) do
			local group = NPC_GROUPS[name]
			groupNames[#groupNames + 1] = (group and group.label) or name
		end
		table.sort(groupNames)
		print("  Группы: " .. table.concat(groupNames, ", "))

		local classKeys = {}
		for cls in pairs(best.FFWL_NPCClasses or {}) do classKeys[#classKeys + 1] = cls end
		print("  NPC-классы: " .. table.concat(classKeys, ", "))

		local teamList = {}
		for teamId, teamData in pairs(team.GetAllTeams()) do
			if best:IsTeamWhitelisted(teamId) then
				teamList[#teamList + 1] = teamData.Name
			end
		end
		print("  Команды: " .. table.concat(teamList, ", "))

		print("  Пресеты: " .. table.Count(FF_PRESETS) .. " (" .. PRESET_FILE .. ")")
		print("  Раскладки (" .. game.GetMap() .. "): " .. table.Count(FF_LAYOUTS[game.GetMap()] or {}) .. " (" .. LAYOUT_FILE .. ")")

		print("  Твой доступ: admin=" .. tostring(ply:IsAdmin()) .. " | flag=" .. tostring(HasEditAccess(ply)) .. " | owner=" .. tostring(IsOwner(ply, best)))
		print("=== конец ===")
	end)
end

--------------------------------------------------------------------
-- SHARED: диагностика
--------------------------------------------------------------------

concommand.Add("ffwl_scan", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end

	local fields = ents.FindByClass(FIELD_CLASS)
	local platforms = ents.FindByClass(PLATFORM_CLASS)

	print("[FFWL] Полей " .. FIELD_CLASS .. " на карте: " .. #fields)
	for _, ent in ipairs(fields) do
		local enabled = "?"
		if ent.GetEnabled then enabled = tostring(ent:GetEnabled()) end
		local ftype = "?"
		if ent.GetForcefieldType then ftype = tostring(ent:GetForcefieldType()) end
		print("  " .. tostring(ent) .. " | enabled=" .. enabled .. " | type=" .. ftype)
	end
	print("[FFWL] Платформ (эмиттеров) " .. PLATFORM_CLASS .. ": " .. #platforms)
end)

--------------------------------------------------------------------
-- CLIENT: меню в стиле SIR, поиск поля взглядом, контекстное меню
--------------------------------------------------------------------

if CLIENT then
	surface.CreateFont("FFWL_Title",      { font = "Roboto", size = 22, weight = 800, extended = true })
	surface.CreateFont("FFWL_Section",    { font = "Roboto", size = 17, weight = 800, extended = true })
	surface.CreateFont("FFWL_SectionSub", { font = "Roboto", size = 13, weight = 400, extended = true })
	surface.CreateFont("FFWL_NavTitle",   { font = "Roboto", size = 15, weight = 700, extended = true })
	surface.CreateFont("FFWL_NavSub",     { font = "Roboto", size = 11, weight = 400, extended = true })
	surface.CreateFont("FFWL_Item",       { font = "Roboto", size = 15, weight = 500, extended = true })
	surface.CreateFont("FFWL_Btn",        { font = "Roboto", size = 14, weight = 700, extended = true })

	local COL_BG         = Color(26, 34, 44)
	local COL_HEADER     = Color(14, 19, 26)
	local COL_SIDEBAR    = Color(20, 27, 36)
	local COL_NAV_ACTIVE = Color(34, 48, 64)
	local COL_ROW        = Color(24, 32, 42)
	local COL_ROW_HOVER  = Color(38, 50, 64)
	local COL_CARD       = Color(31, 41, 52)
	local COL_LINE       = Color(52, 66, 82)
	local COL_TEXT       = Color(222, 230, 238)
	local COL_DIM        = Color(132, 146, 160)
	local COL_ACCENT     = Color(72, 136, 208)
	local COL_ACCENT2    = Color(122, 182, 240)
	local COL_GREEN      = Color(96, 200, 120)
	local COL_RED        = Color(224, 92, 92)
	local COL_DEL_HOVER  = Color(120, 40, 40)

	local function ClientCanEdit(ent)
		local ply = LocalPlayer()
		if not IsValid(ply) then return false end
		if ply:IsAdmin() then return true end
		if ULib and ULib.ucl and ULib.ucl.query(ply, "forcefield_edit") then return true end
		if CPPI and ent.CPPIGetOwner and ent:CPPIGetOwner() == ply then return true end
		return false
	end

	-- Поле ловится геометрией: трейс сквозь него проходит (мод пускает MASK_USE)
	local function GetLookedField()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local eyePos = ply:EyePos()
		local aimDir = ply:GetAimVector()

		local best, bestDist = nil, 70
		for _, ent in ipairs(ents.FindByClass(FIELD_CLASS)) do
			if not IsValid(ent) then continue end
			local center = ent:WorldSpaceCenter()
			local toCenter = center - eyePos
			local proj = toCenter:Dot(aimDir)
			if proj < 10 then continue end
			local closestPoint = eyePos + aimDir * proj
			local distance = closestPoint:Distance(center)
			if distance < bestDist then
				best, bestDist = ent, distance
			end
		end

		return best
	end

	local currentEntity, currentMenu
	local listData = {}
	local activeNav = "core"
	local searchText = ""

	local NAV = {
		{ id = "core",    label = "Основное",    sub = "Field status and overview", icon = Material("icon16/cog.png") },
		{ id = "players", label = "Игроки",      sub = "Player whitelist",          icon = Material("icon16/user.png") },
		{ id = "teams",   label = "Команды",     sub = "Mod team whitelist",        icon = Material("icon16/group.png") },
		{ id = "editors", label = "Редакторы",   sub = "Field editors",             icon = Material("icon16/user_go.png") },
		{ id = "saves",   label = "Сохранения",  sub = "Presets and layouts",       icon = Material("icon16/disk.png") },
		{ id = "groups",  label = "Группы NPC",  sub = "NPC group presets",         icon = Material("icon16/group_link.png") },
		{ id = "npcs",    label = "NPC-классы",  sub = "Individual NPC classes",    icon = Material("icon16/bricks.png") },
	}

	local REMOVE_ACTION = {
		players = "removeplayer",
		teams = "removeteam",
		editors = "removeeditor",
		groups = "removegroup",
		npcs = "removenpcclass",
	}

	local ADD_LABEL = {
		players = "ДОБАВИТЬ ИГРОКА",
		teams = "ДОБАВИТЬ КОМАНДУ",
		editors = "ДОБАВИТЬ РЕДАКТОРА",
		npcs = "ДОБАВИТЬ КЛАСС NPC",
	}

	local LIST_META = {
		players = { title = "ИГРОКИ", desc = "Эти игроки проходят через поле (SteamID)" },
		teams = { title = "КОМАНДЫ", desc = "Штатный вайтлист команд мода силовых полей" },
		editors = { title = "РЕДАКТОРЫ", desc = "Игроки с правом редактирования этого поля" },
		groups = { title = "ГРУППЫ NPC", desc = "Пресеты одним выбором: Combine, Сопротивление, Xen" },
		npcs = { title = "NPC-КЛАССЫ", desc = "Индивидуальные классы NPC, проходящие поле" },
	}

	local function RequestData()
		if not IsValid(currentEntity) then return end
		net.Start("ffwl_request")
		net.WriteEntity(currentEntity)
		net.SendToServer()
	end

	local function SendAction(action, value)
		if not IsValid(currentEntity) then return end
		net.Start("ffwl_action")
		net.WriteEntity(currentEntity)
		net.WriteString(action)
		net.WriteString(value or "")
		net.SendToServer()

		timer.Simple(0.15, function()
			if not IsValid(currentEntity) then return end
			RequestData()
		end)
	end

	local function TabItems(navId)
		local out = {}

		if navId == "players" then
			local ids = listData.PlayerIds or {}
			for i, text in ipairs(listData.Players or {}) do
				out[#out + 1] = { text = text, id = ids[i] or text }
			end
		elseif navId == "teams" then
			local ids = listData.TeamIds or {}
			for i, text in ipairs(listData.Teams or {}) do
				out[#out + 1] = { text = text, id = ids[i] or text }
			end
		elseif navId == "editors" then
			local ids = listData.EditorIds or {}
			for i, text in ipairs(listData.Editors or {}) do
				out[#out + 1] = { text = text, id = ids[i] or text }
			end
		elseif navId == "groups" then
			local ids = listData.GroupIds or {}
			for i, text in ipairs(listData.Groups or {}) do
				out[#out + 1] = { text = text, id = ids[i] or text }
			end
		elseif navId == "npcs" then
			for _, cls in ipairs(listData.NPCClasses or {}) do
				out[#out + 1] = { text = cls, id = cls }
			end
		end

		return out
	end

	net.Receive("ffwl_data", function()
		if not IsValid(currentEntity) then return end
		local ent = net.ReadEntity()
		if ent ~= currentEntity then return end

		listData = net.ReadTable() or {}

		if not IsValid(currentMenu) then return end
		local refresh = currentMenu.FFWL_Refresh
		if refresh then refresh() end
	end)

	net.Receive("ffwl_notify", function()
		chat.AddText(Color(120, 220, 255), net.ReadString())
	end)

	local function PlayerPickerMenu(callback)
		local menu = DermaMenu()
		for _, p in ipairs(player.GetAll()) do
			menu:AddOption(p:Nick() .. " (" .. p:SteamID() .. ")", function() callback(p:SteamID()) end)
		end
		menu:AddSpacer()
		menu:AddOption("Вписать SteamID вручную", function()
			Derma_StringRequest("FFWL", "SteamID игрока (например STEAM_0:1:12345678):", "", function(text)
				if text ~= "" then callback(text) end
			end)
		end)
		menu:Open()
	end

	local function AddActionForTab(navId)
		if navId == "players" then
			return function()
				PlayerPickerMenu(function(sid) SendAction("addplayer", sid) end)
			end
		elseif navId == "teams" then
			return function()
				local menu = DermaMenu()
				for teamId, teamData in pairs(team.GetAllTeams()) do
					menu:AddOption(teamData.Name, function() SendAction("addteam", tostring(teamId)) end)
				end
				menu:Open()
			end
		elseif navId == "editors" then
			return function()
				PlayerPickerMenu(function(sid) SendAction("addeditor", sid) end)
			end
		elseif navId == "npcs" then
			return function()
				Derma_StringRequest("FFWL", "Класс NPC (например npc_vj_automaton_trooper):", "", function(text)
					if text ~= "" then SendAction("addnpcclass", text) end
				end)
			end
		end
		return function() end
	end

	----------------------------------------------------------------
	-- Элементы в стиле SIR: секции, карточки, плитки
	----------------------------------------------------------------

	local function SectionHeader(scroll, title, desc)
		local card = vgui.Create("Panel", scroll)
		card:Dock(TOP)
		card:SetTall(52)
		card:DockMargin(0, 0, 0, 6)
		card.Paint = function(self, w, h)
			draw.RoundedBox(6, 0, 0, w, h, COL_CARD)
			surface.SetDrawColor(COL_LINE.r, COL_LINE.g, COL_LINE.b, 110)
			surface.DrawOutlinedRect(0, 0, w, h)
			draw.RoundedBoxEx(6, 0, 0, 4, h, COL_ACCENT, true, false, false, true)
			draw.SimpleText(title, "FFWL_Section", 16, 9, COL_ACCENT2, TEXT_ALIGN_LEFT)
			draw.SimpleText(desc, "FFWL_SectionSub", 16, 31, COL_DIM, TEXT_ALIGN_LEFT)
		end
	end

	local function InfoCard(scroll, label, value, valueCol)
		local card = vgui.Create("Panel", scroll)
		card:Dock(TOP)
		card:SetTall(38)
		card:DockMargin(0, 0, 0, 6)
		card.Paint = function(self, w, h)
			draw.RoundedBox(4, 0, 0, w, h, COL_ROW)
			surface.SetDrawColor(COL_LINE.r, COL_LINE.g, COL_LINE.b, 90)
			surface.DrawOutlinedRect(0, 0, w, h)
			draw.SimpleText(label, "FFWL_Item", 14, h / 2, COL_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.SimpleText(value, "FFWL_Item", w - 14, h / 2, valueCol or COL_TEXT, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
	end

	local function EmptyLabel(scroll, text)
		local card = vgui.Create("Panel", scroll)
		card:Dock(TOP)
		card:SetTall(46)
		card:DockMargin(0, 0, 0, 6)
		card.Paint = function(self, w, h)
			draw.RoundedBox(4, 0, 0, w, h, COL_ROW)
			surface.SetDrawColor(COL_LINE.r, COL_LINE.g, COL_LINE.b, 60)
			surface.DrawOutlinedRect(0, 0, w, h)
			draw.SimpleText(text, "FFWL_Item", w / 2, h / 2, COL_DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end

	-- Обрезка длинного текста с многоточием (скиссор работал в экранных
	-- координатах и обрезал текст строк целиком)
	local function TruncateText(text, font, maxW)
		surface.SetFont(font)
		if surface.GetTextSize(text) <= maxW then return text end

		while #text > 1 and surface.GetTextSize(text .. "…") > maxW do
			text = string.sub(text, 1, #text - 1)
		end

		return text .. "…"
	end

	local function ListRow(scroll, item, onRemove)
		local row = vgui.Create("DButton", scroll)
		row:Dock(TOP)
		row:SetTall(40)
		row:DockMargin(0, 0, 0, 6)
		row:SetText("")
		row:SetTooltip(item.text)
		row.Paint = function(self, w, h)
			local bg = COL_ROW
			if self:IsHovered() then bg = COL_ROW_HOVER end
			draw.RoundedBox(4, 0, 0, w, h, bg)
			surface.SetDrawColor(COL_LINE.r, COL_LINE.g, COL_LINE.b, self:IsHovered() and 160 or 90)
			surface.DrawOutlinedRect(0, 0, w, h)

			local label = TruncateText(item.text, "FFWL_Item", w - 70)
			draw.SimpleText(label, "FFWL_Item", 14, h / 2, COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
		end

		local del = vgui.Create("DButton", row)
		del:Dock(RIGHT)
		del:SetWide(46)
		del:DockMargin(0, 5, 5, 5)
		del:SetText("")
		del:SetTooltip("Убрать из списка")
		del.Paint = function(self, w, h)
			draw.RoundedBox(3, 0, 0, w, h, self:IsHovered() and COL_DEL_HOVER or COL_CARD)
			draw.SimpleText("✕", "FFWL_Item", w / 2, h / 2, self:IsHovered() and COL_TEXT or COL_RED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		del.DoClick = onRemove
	end

	local function AddTile(scroll, label, onClick)
		local btn = vgui.Create("DButton", scroll)
		btn:Dock(TOP)
		btn:SetTall(44)
		btn:DockMargin(0, 8, 0, 6)
		btn:SetText("")
		btn.Paint = function(self, w, h)
			draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL_NAV_ACTIVE or COL_ROW)
			surface.SetDrawColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, self:IsHovered() and 255 or 140)
			surface.DrawOutlinedRect(0, 0, w, h)
			draw.SimpleText(label, "FFWL_Btn", w / 2, h / 2, self:IsHovered() and COL_ACCENT2 or COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		btn.DoClick = onClick
	end

	local function GroupTile(scroll, group, onAdd)
		local btn = vgui.Create("DButton", scroll)
		btn:Dock(TOP)
		btn:SetTall(52)
		btn:DockMargin(0, 0, 0, 6)
		btn:SetText("")
		btn.Paint = function(self, w, h)
			draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL_NAV_ACTIVE or COL_ROW)
			surface.SetDrawColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, self:IsHovered() and 255 or 140)
			surface.DrawOutlinedRect(0, 0, w, h)
			draw.SimpleText(group.label, "FFWL_NavTitle", 14, 9, COL_TEXT, TEXT_ALIGN_LEFT)
			draw.SimpleText(#group.classes .. " классов NPC", "FFWL_NavSub", 14, 31, COL_DIM, TEXT_ALIGN_LEFT)
			draw.SimpleText("+ ДОБАВИТЬ", "FFWL_Btn", w - 14, h / 2, self:IsHovered() and COL_ACCENT2 or COL_DIM, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		btn.DoClick = onAdd
	end

	-- Строка пресета/раскладки: имя, сводка, основное действие и крестик
	local function SaveRow(scroll, name, summary, primaryLabel, onPrimary, onRemove)
		local row = vgui.Create("DButton", scroll)
		row:Dock(TOP)
		row:SetTall(54)
		row:DockMargin(0, 0, 0, 6)
		row:SetText("")
		row:SetTooltip(name)
		row.Paint = function(self, w, h)
			local bg = COL_ROW
			if self:IsHovered() then bg = COL_ROW_HOVER end
			draw.RoundedBox(4, 0, 0, w, h, bg)
			surface.SetDrawColor(COL_LINE.r, COL_LINE.g, COL_LINE.b, self:IsHovered() and 160 or 90)
			surface.DrawOutlinedRect(0, 0, w, h)

			draw.SimpleText(TruncateText(name, "FFWL_NavTitle", w - 200), "FFWL_NavTitle", 14, 9, COL_TEXT, TEXT_ALIGN_LEFT)
			draw.SimpleText(summary, "FFWL_NavSub", 14, 32, COL_DIM, TEXT_ALIGN_LEFT)
			draw.SimpleText(primaryLabel, "FFWL_Btn", w - 70, h / 2, COL_ACCENT2, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end
		row.DoClick = onPrimary

		local del = vgui.Create("DButton", row)
		del:Dock(RIGHT)
		del:SetWide(46)
		del:DockMargin(0, 5, 5, 5)
		del:SetText("")
		del:SetTooltip("Удалить")
		del.Paint = function(self, w, h)
			draw.RoundedBox(3, 0, 0, w, h, self:IsHovered() and COL_DEL_HOVER or COL_CARD)
			draw.SimpleText("✕", "FFWL_Item", w / 2, h / 2, self:IsHovered() and COL_TEXT or COL_RED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		del.DoClick = onRemove
	end

	local function MatchesFilter(text)
		if searchText == "" then return true end
		return text:lower():find(searchText:lower(), 1, true) ~= nil
	end

	----------------------------------------------------------------
	-- Сборка содержимого
	----------------------------------------------------------------

	local function BuildCore(scroll)
		SectionHeader(scroll, "ОБЗОР ПОЛЯ", "Состояние сущности и сводка вайтлистов")

		local ent = currentEntity
		InfoCard(scroll, "Сущность", IsValid(ent) and tostring(ent) or "—")

		local enabled, enabledCol = "неизвестно", COL_DIM
		if IsValid(ent) and ent.GetEnabled then
			local state = ent:GetEnabled()
			enabled = state and "ВКЛЮЧЕНО" or "ВЫКЛЮЧЕНО"
			enabledCol = state and COL_GREEN or COL_RED
		end
		InfoCard(scroll, "Состояние", enabled, enabledCol)

		if IsValid(ent) and ent.GetForcefieldType then
			InfoCard(scroll, "Тип поля", tostring(ent:GetForcefieldType()))
		end

		SectionHeader(scroll, "СВОДКА ВАЙТЛИСТОВ", "Сколько записей сейчас на этом поле")
		InfoCard(scroll, "Игроки", tostring(#(listData.Players or {})))
		InfoCard(scroll, "Команды", tostring(#(listData.Teams or {})))
		InfoCard(scroll, "Редакторы", tostring(#(listData.Editors or {})))
		InfoCard(scroll, "Группы NPC", tostring(#(listData.Groups or {})))
		InfoCard(scroll, "NPC-классы", tostring(#(listData.NPCClasses or {})))
		InfoCard(scroll, "Пресеты", tostring(#(listData.Presets or {})))
		InfoCard(scroll, "Раскладки", tostring(#(listData.Layouts or {})))

		SectionHeader(scroll, "УПРАВЛЕНИЕ", "Способы открыть это меню")
		InfoCard(scroll, "E по полю", "открывает это меню")
		InfoCard(scroll, "Контекстное меню", "пункт Forcefield Menu")
		InfoCard(scroll, "Консоль / чат", "ffwl_menu / !ffmenu")
	end

	local function BuildSaves(scroll)
		SectionHeader(scroll, "ПРЕСЕТЫ НАСТРОЕК", "Снимок вайтлистов и типа поля по имени")

		AddTile(scroll, "СОХРАНИТЬ ТЕКУЩЕЕ ПОЛЕ", function()
			Derma_StringRequest("FFWL", "Имя пресета:", "", function(text)
				if text ~= "" then SendAction("savepreset", text) end
			end)
		end)

		if #(listData.Presets or {}) == 0 then
			EmptyLabel(scroll, "— пресетов нет —")
		end

		for _, preset in ipairs(listData.Presets or {}) do
			if MatchesFilter(preset.name) then
				local summary = string.format(
					"Игроки %d · Редакторы %d · Группы %d · Классы %d · Команды %d · Тип %s",
					preset.players or 0, preset.editors or 0, preset.groups or 0,
					preset.classes or 0, preset.teams or 0, tostring(preset.fieldtype or "—"))

				SaveRow(scroll, preset.name, summary, "ПРИМЕНИТЬ",
					function()
						Derma_Query("Заменить все списки поля на пресет «" .. preset.name .. "»?", "FFWL",
							"Применить", function() SendAction("applypreset", preset.name) end,
							"Отмена", function() end)
					end,
					function()
						Derma_Query("Удалить пресет «" .. preset.name .. "»?", "FFWL",
							"Удалить", function() SendAction("removepreset", preset.name) end,
							"Отмена", function() end)
					end)
			end
		end

		if listData.CanLayouts then
			SectionHeader(scroll, "РАСКЛАДКИ КАРТЫ", "Позиции всех полей и эмиттеров с настройками")

			AddTile(scroll, "СОХРАНИТЬ РАСКЛАДКУ КАРТЫ", function()
				Derma_StringRequest("FFWL", "Имя раскладки:", "", function(text)
					if text ~= "" then SendAction("savelayout", text) end
				end)
			end)

			if #(listData.Layouts or {}) == 0 then
				EmptyLabel(scroll, "— раскладок нет —")
			end

			for _, layout in ipairs(listData.Layouts or {}) do
				if MatchesFilter(layout.name) then
					local summary = string.format("Полей %d · Эмиттеров %d", layout.fields or 0, layout.platforms or 0)

					SaveRow(scroll, layout.name, summary, "ЗАГРУЗИТЬ",
						function()
							Derma_Query("Загрузить раскладку «" .. layout.name .. "»? Текущие поля и эмиттеры будут удалены и воссозданы по снимку.", "FFWL",
								"Загрузить", function() SendAction("loadlayout", layout.name) end,
								"Отмена", function() end)
						end,
						function()
							Derma_Query("Удалить раскладку «" .. layout.name .. "»?", "FFWL",
								"Удалить", function() SendAction("removelayout", layout.name) end,
								"Отмена", function() end)
						end)
				end
			end
		end

		SectionHeader(scroll, "ОПАСНАЯ ЗОНА", "Полная очистка вайтлистов текущего поля")

		local resetBtn = vgui.Create("DButton", scroll)
		resetBtn:Dock(TOP)
		resetBtn:SetTall(44)
		resetBtn:DockMargin(0, 0, 0, 6)
		resetBtn:SetText("")
		resetBtn.Paint = function(self, w, h)
			draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and COL_DEL_HOVER or COL_ROW)
			surface.SetDrawColor(COL_RED.r, COL_RED.g, COL_RED.b, self:IsHovered() and 255 or 140)
			surface.DrawOutlinedRect(0, 0, w, h)
			draw.SimpleText("СБРОСИТЬ ПОЛЕ", "FFWL_Btn", w / 2, h / 2, COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		resetBtn.DoClick = function()
			Derma_Query("Очистить все вайтлисты этого поля (игроки, редакторы, NPC, команды)?", "FFWL",
				"Сбросить", function() SendAction("resetfield", "") end,
				"Отмена", function() end)
		end
	end

	local function BuildList(scroll, navId)
		local meta = LIST_META[navId] or { title = "?", desc = "" }
		SectionHeader(scroll, meta.title, meta.desc)

		local items = TabItems(navId)

		local shown = {}
		for _, it in ipairs(items) do
			if MatchesFilter(it.text) then shown[#shown + 1] = it end
		end

		if #shown == 0 then
			EmptyLabel(scroll, (#items == 0) and "— пусто —" or "Ничего не найдено по фильтру")
		end

		for _, item in ipairs(shown) do
			ListRow(scroll, item, function()
				SendAction(REMOVE_ACTION[navId], item.id)
			end)
		end

		if navId == "groups" then
			SectionHeader(scroll, "ДОСТУПНЫЕ ПРЕСЕТЫ", "Выбери группу — она вписывается целиком")

			local added = {}
			for _, id in ipairs(listData.GroupIds or {}) do added[id] = true end

			local names = {}
			for gid in pairs(NPC_GROUPS) do names[#names + 1] = gid end
			table.sort(names, function(a, b) return NPC_GROUPS[a].label < NPC_GROUPS[b].label end)

			local any = false
			for _, gid in ipairs(names) do
				if not added[gid] then
					any = true
					GroupTile(scroll, NPC_GROUPS[gid], function()
						SendAction("addgroup", gid)
					end)
				end
			end

			if not any then
				EmptyLabel(scroll, "Все пресеты уже добавлены на это поле")
			end
		else
			AddTile(scroll, ADD_LABEL[navId] or "ДОБАВИТЬ", AddActionForTab(navId))
		end
	end

	local function RebuildContent(scroll)
		if not IsValid(scroll) then return end
		scroll:Clear()

		if activeNav == "core" then
			BuildCore(scroll)
		elseif activeNav == "saves" then
			BuildSaves(scroll)
		else
			BuildList(scroll, activeNav)
		end
	end

	local function OpenMenu(ent)
		if not IsValid(ent) then return end

		if not ClientCanEdit(ent) then
			chat.AddText(Color(255, 100, 100), "[FFWL] Нет прав для редактирования этого поля")
			return
		end

		currentEntity = ent
		activeNav = "core"
		searchText = ""
		RequestData()

		if IsValid(currentMenu) then currentMenu:Remove() end

		local frame = vgui.Create("DFrame")
		currentMenu = frame
		frame:SetSize(960, 620)
		frame:Center()
		frame:SetTitle("")
		frame:ShowCloseButton(false)
		frame:MakePopup()

		-- Шапка: заголовок модуля + крестик закрытия
		local header = vgui.Create("Panel", frame)
		header:Dock(TOP)
		header:SetTall(64)
		header.Paint = function(self, w, h)
			draw.RoundedBoxEx(8, 0, 0, w, h, COL_HEADER, true, true, false, false)
			surface.SetDrawColor(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 255)
			surface.DrawRect(0, h - 2, w, 2)
			draw.SimpleText("FFWL — FORCEFIELD MANAGER", "FFWL_Title", 20, 14, COL_ACCENT2, TEXT_ALIGN_LEFT)
			draw.SimpleText("Менеджер вайтлистов силового поля", "FFWL_SectionSub", 20, 42, COL_DIM, TEXT_ALIGN_LEFT)
			draw.SimpleText(tostring(ent), "FFWL_NavSub", w - 66, h / 2, COL_DIM, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
		end

		local closeBtn = vgui.Create("DButton", header)
		closeBtn:Dock(RIGHT)
		closeBtn:SetWide(48)
		closeBtn:SetText("")
		closeBtn:SetTooltip("Закрыть")
		closeBtn.Paint = function(self, w, h)
			draw.RoundedBoxEx(8, w - 40, 12, 30, 30, self:IsHovered() and COL_DEL_HOVER or COL_ROW, true, true, true, true)
			draw.SimpleText("✕", "FFWL_Item", w - 25, h / 2, self:IsHovered() and COL_TEXT or COL_DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
		closeBtn.DoClick = function()
			if IsValid(frame) then frame:Remove() end
		end

		-- Боковая навигация: поиск + пункты с иконками и подписями
		local sidebar = vgui.Create("Panel", frame)
		sidebar:Dock(LEFT)
		sidebar:SetWide(250)
		sidebar:DockMargin(10, 10, 10, 10)
		sidebar.Paint = function(self, w, h)
			draw.RoundedBox(6, 0, 0, w, h, COL_SIDEBAR)
		end

		local search = vgui.Create("DTextEntry", sidebar)
		search:Dock(TOP)
		search:SetTall(34)
		search:DockMargin(12, 12, 12, 10)
		search:SetPlaceholderText("Поиск настроек…")
		search:SetFont("FFWL_Item")
		search.OnChange = function(self)
			searchText = self:GetValue() or ""
			frame.FFWL_Refresh()
		end

		for _, item in ipairs(NAV) do
			local btn = vgui.Create("DButton", sidebar)
			btn:Dock(TOP)
			btn:SetTall(54)
			btn:DockMargin(10, 0, 10, 4)
			btn:SetText("")
			btn.Paint = function(self, w, h)
				local active = (activeNav == item.id)
				if active then
					draw.RoundedBox(4, 0, 0, w, h, COL_NAV_ACTIVE)
					draw.RoundedBoxEx(4, 0, 0, 4, h, COL_ACCENT, true, false, false, true)
				elseif self:IsHovered() then
					draw.RoundedBox(4, 0, 0, w, h, COL_ROW_HOVER)
				end

				if item.icon then
					surface.SetMaterial(item.icon)
					surface.SetDrawColor(active and COL_ACCENT2.r or COL_DIM.r, active and COL_ACCENT2.g or COL_DIM.g, active and COL_ACCENT2.b or COL_DIM.b, 255)
					surface.DrawTexturedRect(14, h / 2 - 8, 16, 16)
				end

				draw.SimpleText(item.label, "FFWL_NavTitle", 42, 11, COL_TEXT, TEXT_ALIGN_LEFT)
				draw.SimpleText(item.sub, "FFWL_NavSub", 42, 31, COL_DIM, TEXT_ALIGN_LEFT)
			end
			btn.DoClick = function()
				if activeNav == item.id then return end
				activeNav = item.id
				frame.FFWL_Refresh()
			end
		end

		-- Содержимое: секции и карточки
		local content = vgui.Create("DScrollPanel", frame)
		content:Dock(FILL)
		content:DockMargin(0, 10, 10, 10)

		local vbar = content:GetVBar()
		vbar:SetWide(6)
		vbar.Paint = function(self, w, h) draw.RoundedBox(3, 0, 0, w, h, COL_ROW) end
		vbar.btnGrip.Paint = function(self, w, h) draw.RoundedBox(3, 0, 0, w, h, COL_LINE) end
		vbar.btnUp.Paint = function() end
		vbar.btnDown.Paint = function() end

		frame.FFWL_Refresh = function()
			if IsValid(frame) then RebuildContent(content) end
		end

		frame.FFWL_Refresh()
	end

	-- Клавиша E по полю открывает меню (без автоповтора)
	local useKeyHeld = false
	hook.Add("Think", "FFWL_UseKey", function()
		if not input.IsKeyDown(KEY_E) then
			useKeyHeld = false
			return
		end
		if useKeyHeld then return end
		useKeyHeld = true

		if gui.IsGameUIVisible() then return end
		if IsValid(vgui.GetKeyboardFocus()) then return end

		local ent = GetLookedField()
		if not IsValid(ent) then return end
		if not ClientCanEdit(ent) then return end

		OpenMenu(ent)
	end)

	concommand.Add("ffwl_menu", function()
		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local ent = GetLookedField()

		-- Трейс может поймать платформу-эмиттер: возьмём её поле
		if not IsValid(ent) then
			local traceEnt = ply:GetEyeTrace().Entity
			if IsValid(traceEnt) and traceEnt:GetClass() == PLATFORM_CLASS then
				local field = nil
				if traceEnt.GetFieldEntity then field = traceEnt:GetFieldEntity() end
				if IsValid(field) then ent = field end
			end
		end

		if not IsValid(ent) then
			chat.AddText(Color(255, 100, 100), "[FFWL] Поле не найдено — наведись на силовое поле")
			return
		end

		OpenMenu(ent)
	end)

	hook.Add("OnPlayerChat", "FFWL_ChatCommand", function(ply, text)
		if ply ~= LocalPlayer() then return end
		if text:lower() == "!ffmenu" then
			RunConsoleCommand("ffwl_menu")
			return true
		end
	end)

	properties.Add("ffwl_menu", {
		MenuLabel = "Forcefield Menu",
		MenuIcon = "icon16/shield_add.png",
		Order = 606,

		Filter = function(self, ent, ply)
			if not IsValid(ent) or ent:GetClass() ~= FIELD_CLASS then return false end
			return ClientCanEdit(ent)
		end,

		Action = function(self, ent)
			OpenMenu(ent)
		end
	})
end