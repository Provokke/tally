--!strict
-- Tally.claimStreak: the rollback is left until the save has returned, so a queued autosave can store the failed claim first.
return {
	name = "claim_undo_outside_lock",
	file = "src/server/Tally.luau",
	find = [==[if not deps.profiles.save(userId, profile, undo) then]==],
	replace = [==[if not deps.profiles.save(userId, profile) then]==],
}
