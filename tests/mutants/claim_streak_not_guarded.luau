--!strict
-- Tally.claimStreak: a second claim for the same player is let in while the first is running.
return {
	name = "claim_streak_not_guarded",
	file = "src/server/Tally.luau",
	find = [==[if self.calling[userId] then]==],
	replace = [==[if false then]==],
}
