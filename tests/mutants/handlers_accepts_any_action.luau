--!strict
-- Handlers: record and score are valid actions.
return {
	name = "handlers_accepts_any_action",
	file = "src/server/Handlers.luau",
	find = [==[local ACTIONS: { [string]: boolean } = { claim_streak = true, board_page = true }]==],
	replace = [==[local ACTIONS: { [string]: boolean } = { claim_streak = true, board_page = true, record = true, score = true }]==],
}
