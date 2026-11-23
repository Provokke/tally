--!strict
-- Season.matches: a key from another window is accepted.
return {
	name = "season_window_unchecked",
	file = "src/server/Season.luau",
	find = [==[return type(stored) == "table" and stored.startsAt == startsAt and stored.endsAt == endsAt]==],
	replace = [==[return true]==],
}
