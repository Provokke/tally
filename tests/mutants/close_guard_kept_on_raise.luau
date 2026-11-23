--!strict
-- closeSeason: a close that raises leaves the season locked for the life of the server.
return {
	name = "close_guard_kept_on_raise",
	file = "src/server/Tally.luau",
	find = [==[	self.closing[id] = nil
	if not ok then]==],
	replace = [==[	if not ok then]==],
}
