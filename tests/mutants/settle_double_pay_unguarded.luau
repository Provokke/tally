--!strict
-- Tally.settle and Payout.decide: both paid-flag guards removed, so a second settle credits the Coins again.
return {
	name = "settle_double_pay_unguarded",
	file = "src/server/Tally.luau",
	find = [==[if id ~= nil and id < currentId and not entry.rewarded and entry.score > 0 then]==],
	replace = [==[if id ~= nil and id < currentId and entry.score > 0 then]==],
	more = {
		{
			file = "src/server/Payout.luau",
			find = [==[if entry.rewarded then]==],
			replace = [==[if false then]==],
		},
	},
}
