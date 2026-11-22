--!strict
-- Tally.claimStreak: a failed save puts the whole old streak back, losing a field changed while the save was in flight.
return {
	name = "streak_rollback_whole_table",
	file = "src/server/Tally.luau",
	find = [==[for _, field in STREAK_FIELDS do]==],
	replace = [==[profile.streak = before
		for _, field in {} do]==],
}
