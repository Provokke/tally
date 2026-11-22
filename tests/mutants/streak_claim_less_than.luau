--!strict
-- Streak.claim: a second claim on the same day goes through.
return {
	name = "streak_claim_less_than",
	file = "src/server/Streak.luau",
	find = "if today <= current.day then",
	replace = "if today < current.day then",
}
