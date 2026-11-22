--!strict
-- Tally.claimStreak: the Coins are saved first and the streak in a second save.
return {
	name = "streak_separate_save",
	file = "src/server/Tally.luau",
	find = [==[profile.streak = claimed.streak]==],
	replace = [==[do
	profile.coins += claimed.reward
	if not deps.profiles.save(userId, profile) then
		profile.coins -= claimed.reward
		return false, "save_failed", nil
	end
	profile.streak = claimed.streak
	deps.profiles.save(userId, profile)
	return true, nil, claimed.reward
	end]==],
}
