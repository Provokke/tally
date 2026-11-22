--!strict
-- Tally.claimStreak: a failed save sets the Coins back to what they were when the claim began, losing any change made while the save was in flight.
return {
	name = "claim_rollback_from_snapshot",
	file = "src/server/Tally.luau",
	find = [==[if not deps.profiles.save(userId, profile, undo) then]==],
	replace = [==[local startCoins = profile.coins - claimed.reward
	local saved = deps.profiles.save(userId, profile, undo)
	if not saved then
		profile.coins = startCoins + claimed.reward]==],
}
