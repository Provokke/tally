--!strict
-- Leaderboard.top: every Browse call reads the ordered store.
return {
	name = "browse_no_refresh_cache",
	file = "src/server/Leaderboard.luau",
	find = "if cached ~= nil and now - cached.at < self.deps.refreshSeconds then",
	replace = "if false then",
}
