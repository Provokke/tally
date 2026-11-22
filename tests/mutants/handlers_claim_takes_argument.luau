--!strict
-- Handlers: claim_streak accepts an argument.
return {
	name = "handlers_claim_takes_argument",
	file = "src/server/Handlers.luau",
	find = [==[return a == nil]==],
	replace = [==[return true]==],
}
