--!strict
-- Tally.settle: the podium bonus is read from the live board, not the stored close.
return {
	name = "podium_from_live_board",
	file = "src/server/Tally.luau",
	find = "local decision = deps.Payout.decide(entry, season, id, currentId, userId, closeClock(self), rules)",
	replace = [==[if season ~= nil and season.state == "closed" then
				season = {
					id = season.id,
					endsAt = season.endsAt,
					state = season.state,
					podium = deps.leaderboard:read(id, deps.config.PodiumSize) or {},
				}
			end
			local decision = deps.Payout.decide(entry, season, id, currentId, userId, closeClock(self), rules)]==],
}
