--!strict
-- closeSeason: a board read that works does not clear the failure, so an old outage counts against a new one.
return {
	name = "podium_wait_never_clears",
	file = "src/server/Tally.luau",
	find = [==[	else
		self.boardFailedAt[id] = nil
	end]==],
	replace = [==[	end]==],
}
