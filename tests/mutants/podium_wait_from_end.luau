--!strict
-- closeSeason: the podium wait is measured from the season end, so a late first close freezes an empty podium on one failed read.
return {
	name = "podium_wait_from_end",
	file = "src/server/Tally.luau",
	find = [==[local waiting = now - outage.first < deps.config.PodiumWaitSeconds]==],
	replace = [==[local waiting = closeClock(self) < endsAt + deps.config.PodiumWaitSeconds]==],
}
