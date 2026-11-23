--!strict
-- closeSeason: a failed board read closes with an empty podium at once.
return {
	name = "podium_wait_none",
	file = "src/server/Tally.luau",
	find = [==[if deps.now() - failedAt < deps.config.PodiumWaitSeconds then]==],
	replace = [==[if false then]==],
}
