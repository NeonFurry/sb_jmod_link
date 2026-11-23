--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Fusion Generator (v2.4)
	Патч Fusion Generators (generator_energy_fusion) из SpaceBuild /
	SpaceBuild Life Support по реальной RD3-механике (проверено по
	исходникам github.com/spacebuild/spacebuild, файл
	lua/caf/addons/server/resourcedistribution.lua):

	  1. Без повреждений  — EntityTakeDamage блокируется + перехват
	     CAF Life Support DamageLS (урон от перегрева/нехватки воды).
	  2. Лимит воды       — ёмкость БАКА ПРИБОРА (меняется дельтой и в
	     nettable.maxvalue; сетевое значение воды не трогается).
	  3. Лимит энергии    — ЭТО КЛАМП ЗНАЧЕНИЯ СЕТИ (nettable value), а
	     не только ёмкости прибора: в RD3 «energy» хранится один раз на
	     всю сеть, поэтому лимит энергии ограничивает запас ВСЕЙ сети,
	     включая банки (storage_energy). Ёмкость юнита тоже режется
	     (min(заводская, лимит)) и учитывается в transfer.lua через
	     F.Capacity.
	  4. Бесконечная вода — расход воды НЕ списывается вообще:
	     ConsumeResource("water") генератора ничего не тратит, а для
	     ВСЕЙ RD-сети, куда влит генератор, патчатся глобальные
	     RD.ConsumeResource / RD.ConsumeNetResource (расход «засчитан»,
	     списания нет). Фоновый доливатель держит полным и бак прибора,
	     и сетевой запас — на случай любых прочих путей расхода
	     (насосы, transfer между сетями, прямые обращения к RD).

	Как правильно менять ЁМКОСТЬ и ЗАПАС в RD3 (почему старые версии
	«не работали»):
	  * SetResourceAmount в RD3 НЕ СУЩЕСТВУЕТ — pcall по нему молча
	    падал и ничего не происходило.
	  * RD.AddResource(ent, res, max, default) присваивает value =
	    default, то есть обнуляет/портит содержимое бака.
	  * Для устройства в сети (index.network ~= 0) все Supply/Consume/
	    Get работают с nettable[net].resources[res], а его maxvalue —
	    это
