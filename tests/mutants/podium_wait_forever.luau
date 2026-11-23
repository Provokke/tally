--!strict
-- closeSeason: a board that never comes back blocks the close for ever.
return {
	name = "podium_wait_forever",
	file = "src/server/Tally.luau",
	find = [==[local waiting = now - outage.first < deps.config.PodiumWaitSeconds]==],
	replace = [==[local waiting = true]==],
}
