--!strict
-- closeSeason: every player settling at once starts a close of their own.
return {
	name = "close_not_exclusive",
	file = "src/server/Tally.luau",
	find = [==[	if self.closing[id] then
		return nil
	end
]==],
	replace = [==[]==],
}
