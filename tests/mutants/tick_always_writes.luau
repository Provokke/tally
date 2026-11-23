--!strict
-- Tally.ensureOpen: the key is written every tick, whether or not it exists.
return {
	name = "tick_always_writes",
	file = "src/server/Tally.luau",
	find = [==[	if stored ~= nil then
		return accept(self, id, stored)
	end]==],
	replace = [==[	if false then
		return accept(self, id, stored)
	end]==],
}
