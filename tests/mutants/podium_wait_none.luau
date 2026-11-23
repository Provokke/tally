--!strict
-- closeSeason: a failed board read closes with an empty podium at once.
return {
	name = "podium_wait_none",
	file = "src/server/Tally.luau",
	find = [==[local waiting = now - outage.first < deps.config.PodiumWaitSeconds]==],
	replace = [==[local waiting = false]==],
}
