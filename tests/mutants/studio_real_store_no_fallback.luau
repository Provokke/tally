--!strict
-- Server script: a failed real store acquisition in Studio is rethrown, so the script stops.
return {
	name = "studio_real_store_no_fallback",
	file = "src/server/init.server.luau",
	find = "if not RunService:IsStudio() then\n\t\t\terror(problem, 0)",
	replace = "if true then\n\t\t\terror(problem, 0)",
}
