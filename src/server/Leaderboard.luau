--!strict
-- The per-season leaderboard. A cache, never the source of truth: the profile holds the score.
-- push writes a player's score on a timer; top serves Browse from a per-server cache that is
-- refreshed at most once per window; read is the one uncached read, used at the close write to
-- freeze the podium into the season key. read answers nil and a reason when the board can't be
-- read, never an empty list, so a caller can tell a board that is down from a board with no scores.
local Leaderboard = {}
Leaderboard.__index = Leaderboard

export type Entry = { userId: number, score: number }
export type Deps = {
	store: (seasonId: number) -> any,
	now: () -> number,
	size: number,
	refreshSeconds: number,
	log: (message: string) -> (),
}

export type Leaderboard = typeof(setmetatable(
	{} :: {
		deps: Deps,
		cache: { [number]: { at: number, entries: { Entry } } },
		pushed: { [string]: number },
	},
	Leaderboard
))

function Leaderboard.new(deps: Deps): Leaderboard
	return setmetatable({ deps = deps, cache = {}, pushed = {} }, Leaderboard)
end

function Leaderboard.read(self: Leaderboard, seasonId: number, count: number): ({ Entry }?, string?)
	local ok, page = pcall(function()
		local pages = self.deps.store(seasonId):GetSortedAsync(false, math.min(count, 100))
		return pages:GetCurrentPage()
	end)
	if not ok then
		return nil, tostring(page)
	end
	local entries: { Entry } = {}
	for _, row in page do
		local userId = tonumber(row.key)
		if userId ~= nil and userId % 1 == 0 and userId > 0 and row.value > 0 then
			table.insert(entries, { userId = userId, score = row.value })
		end
	end
	table.sort(entries, function(a: Entry, b: Entry): boolean
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.userId < b.userId
	end)
	while #entries > count do
		table.remove(entries)
	end
	return entries, nil
end

-- The cached read behind Browse. The window is claimed before the read starts.
function Leaderboard.top(self: Leaderboard, seasonId: number): { Entry }
	local now = self.deps.now()
	local cached = self.cache[seasonId]
	if cached ~= nil and now - cached.at < self.deps.refreshSeconds then
		return cached.entries
	end
	local previous: { Entry } = if cached ~= nil then cached.entries else {}
	self.cache = { [seasonId] = { at = now, entries = previous } } -- keep only the season being shown
	local entries, why = self:read(seasonId, self.deps.size)
	if entries == nil then
		self.deps.log(`leaderboard read failed for season {seasonId}: {tostring(why)}`)
		return previous
	end
	self.cache[seasonId] = { at = now, entries = entries }
	return entries
end

function Leaderboard.push(self: Leaderboard, seasonId: number, userId: number, score: number): boolean
	if score <= 0 then
		return true
	end
	local key = `{seasonId}:{userId}`
	if self.pushed[key] == score then
		return true
	end
	local ok, err = pcall(function()
		self.deps.store(seasonId):SetAsync(tostring(userId), score)
	end)
	if not ok then
		self.deps.log(`leaderboard write failed for {userId}: {tostring(err)}`)
		return false
	end
	self.pushed[key] = score
	return true
end

return Leaderboard
