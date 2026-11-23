--!strict
-- closeSeason: the podium wait is measured from the season end, so a late first close freezes an empty podium on one failed read.
return {
	name = "podium_wait_from_end",
	file = "src/server/Tally.luau",
	find = [==[if deps.now() - failedAt < deps.config.PodiumWaitSeconds then]==],
	replace = [==[if closeClock(self) < select(2, deps.Season.window(deps.config.Epoch, deps.length, id)) + deps.config.PodiumWaitSeconds then]==],
}
