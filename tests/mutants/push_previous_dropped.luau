--!strict
-- Tally.push: only the current season is pushed, so the last push interval of a season never reaches its board.
return {
	name = "push_previous_dropped",
	file = "src/server/Tally.luau",
	find = [==[if previous >= 1 and pushesPrevious(self, previous, profile) then]==],
	replace = [==[if false then]==],
}
