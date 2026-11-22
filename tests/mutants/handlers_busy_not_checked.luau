--!strict
-- Handlers: a call is let in while another for the same player is running.
return {
	name = "handlers_busy_not_checked",
	file = "src/server/Handlers.luau",
	find = [==[if self:busy(userId) then]==],
	replace = [==[if false then]==],
}
