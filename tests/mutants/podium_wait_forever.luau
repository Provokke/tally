--!strict
-- closeSeason: a board that never comes back blocks the close for ever.
return {
	name = "podium_wait_forever",
	file = "src/server/Tally.luau",
	find = [==[if deps.now() - failedAt < deps.config.PodiumWaitSeconds then]==],
	replace = [==[if true then]==],
}
