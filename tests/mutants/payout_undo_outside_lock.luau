--!strict
-- Tally.settle: the payout rollback is left until the save has returned, so a queued autosave can store the failed payout first.
return {
	name = "payout_undo_outside_lock",
	file = "src/server/Tally.luau",
	find = [==[local saved = deps.profiles.save(userId, profile, undo)]==],
	replace = [==[local saved = deps.profiles.save(userId, profile)]==],
}
