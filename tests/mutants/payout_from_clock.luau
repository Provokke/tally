--!strict
-- Tally.settle: a season is treated as closed from the clock, with no close write.
return {
	name = "payout_from_clock",
	file = "src/server/Tally.luau",
	find = "season = closeSeason(self, id, season)",
	replace = 'season = deps.Season.close(season, deps.now(), {}, "clock") or season',
}
