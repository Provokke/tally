--!strict
-- Payout.apply: Coins paid without recording that they were.
return {
	name = "reward_without_rewarded",
	file = "src/server/Payout.luau",
	find = "entry.rewarded = true",
	replace = "entry.rewarded = false",
}
