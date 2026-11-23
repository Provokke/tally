--!strict
-- Tally.push: a paid season is pushed again, a board write for nothing.
return {
	name = "push_previous_when_paid",
	file = "src/server/Tally.luau",
	find = [==[if entry == nil or entry.rewarded then]==],
	replace = [==[if entry == nil then]==],
}
