--!strict
-- Tally.record: a score is recorded into a season whose key is from another window.
return {
	name = "mismatch_record_allowed",
	file = "src/server/Tally.luau",
	find = [==[	if self.mismatched[id] then
		return false, "season_mismatch"
	end
]==],
	replace = [==[]==],
}
