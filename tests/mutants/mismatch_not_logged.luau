--!strict
-- Tally.accept: a refused season is not reported.
return {
	name = "mismatch_not_logged",
	file = "src/server/Tally.luau",
	find = [==[		if not self.mismatched[id] then
			self.mismatched[id] = true]==],
	replace = [==[		if false then
			self.mismatched[id] = true]==],
}
