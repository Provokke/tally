--!strict
-- Tally.settle: a failed payout save restores the Coins to a snapshot taken before the payout, losing any change made while it was in flight.
return {
	name = "rollback_from_snapshot",
	file = "src/server/Tally.luau",
	find = "local undo = deps.Payout.apply(profile, key, decision)",
	replace = [==[local before = profile.coins
	local applied = deps.Payout.apply(profile, key, decision)
	local undo = setmetatable({ key = key }, {
		__index = function(_, field)
			if field == "coins" then
				return profile.coins - before
			end
			return applied[field]
		end,
	})]==],
}
