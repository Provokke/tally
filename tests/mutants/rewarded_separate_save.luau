--!strict
-- Tally.settle: Coins are saved first and the paid flag in a second save.
return {
	name = "rewarded_separate_save",
	file = "src/server/Tally.luau",
	find = "local undo = deps.Payout.apply(profile, key, decision)",
	replace = [==[local undo = { key = key, coins = decision.coins :: number }
	profile.coins += undo.coins
	if not deps.profiles.save(userId, profile) then
		return false
	end
	profile.seasons[key].rewarded = true]==],
}
