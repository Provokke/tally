--!strict
-- Payout.decide: a season already paid is decided again, so a second settle credits the Coins again.
return {
	name = "settle_ignores_rewarded",
	file = "src/server/Payout.luau",
	find = "if entry.rewarded then",
	replace = "if false then",
}
