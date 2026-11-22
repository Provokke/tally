--!strict
-- ConfigCheck: a store cost above the burst is accepted, so a call that can never be afforded passes.
return {
	name = "store_cost_over_burst_allowed",
	file = "src/shared/ConfigCheck.luau",
	find = [==[if cost.claim_streak > limits.StoreBurstPerPlayer then]==],
	replace = [==[if false then]==],
}
