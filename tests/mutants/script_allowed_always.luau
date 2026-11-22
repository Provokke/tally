--!strict
-- The entry script: a call is allowed for a session that would not be saved.
return {
	name = "script_allowed_always",
	file = "src/server/init.server.luau",
	find = [==[return sessions:writableSession(userId) ~= nil
	end,
	setPage]==],
	replace = [==[return true
	end,
	setPage]==],
}
