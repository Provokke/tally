--!strict
-- Tally.settle: a refused season is opened and read again on every poll.
return {
	name = "mismatch_settle_rereads",
	file = "src/server/Tally.luau",
	find = [==[		if season == nil and self.mismatched[id] then
			continue -- its stored window is not the config's: nothing to open, close or pay
		end
]==],
	replace = [==[]==],
}
