--!strict
-- closeSeason: the latest failed attempt is not recorded, so a long outage keeps restarting and never closes.
return {
	name = "podium_wait_last_not_updated",
	file = "src/server/Tally.luau",
	find = [==[		outage.last = now
		local _, endsAt]==],
	replace = [==[		local _, endsAt]==],
}
