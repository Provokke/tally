--!strict
-- Handlers: the per-player rate limiter is not consulted.
return {
	name = "handlers_no_rate_limit",
	file = "src/server/Handlers.luau",
	find = [==[if not valid(deps, action, a) or not deps.limiter:take(userId) then]==],
	replace = [==[if not valid(deps, action, a) then]==],
}
