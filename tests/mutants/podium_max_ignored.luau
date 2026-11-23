--!strict
-- closeSeason: a board that stays down is waited for beyond PodiumMaxSeconds after the end.
return {
	name = "podium_max_ignored",
	file = "src/server/Tally.luau",
	find = [==[local pastMax = closeClock(self) >= endsAt + deps.config.PodiumMaxSeconds]==],
	replace = [==[local pastMax = false]==],
}
