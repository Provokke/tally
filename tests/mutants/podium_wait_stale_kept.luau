--!strict
-- closeSeason: an outage timer is never restarted, so an old first failure makes one new failure close the season empty.
return {
	name = "podium_wait_stale_kept",
	file = "src/server/Tally.luau",
	find = [==[if outage == nil or now - outage.last > 2 * deps.config.SettleSeconds then]==],
	replace = [==[if outage == nil then]==],
}
