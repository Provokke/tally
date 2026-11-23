--!strict
-- closeSeason: the PodiumMaxSeconds limit is reached one second late.
return {
	name = "podium_max_off_by_one",
	file = "src/server/Tally.luau",
	find = [==[local pastMax = closeClock(self) >= endsAt + deps.config.PodiumMaxSeconds]==],
	replace = [==[local pastMax = closeClock(self) > endsAt + deps.config.PodiumMaxSeconds]==],
}
