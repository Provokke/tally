--!strict
-- Tally.accept: a key that matches again is still refused.
return {
	name = "mismatch_flag_never_clears",
	file = "src/server/Tally.luau",
	find = [==[	self.mismatched[id] = nil
]==],
	replace = [==[]==],
}
