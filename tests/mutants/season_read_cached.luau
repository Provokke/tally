--!strict
-- Tally.fetch: a season read may come from the local cache.
return {
	name = "season_read_cached",
	file = "src/server/Tally.luau",
	find = [==[self.deps.seasons:GetAsync(self.deps.Season.key(id), self.deps.readOptions)]==],
	replace = [==[self.deps.seasons:GetAsync(self.deps.Season.key(id))]==],
}
