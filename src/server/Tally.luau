--!strict
-- The season service: which season is current, opening its key, recording scores and pushing
-- them to the board. It orders reads and writes; every decision comes from the pure modules,
-- which are passed in (this file requires nothing).
local Tally = {}
Tally.__index = Tally

export type Deps = {
	seasons: any, -- a DataStore handle: UpdateAsync and GetAsync
	leaderboard: any, -- a Leaderboard
	profiles: { get: (userId: number) -> any?, save: (userId: number, staked: any) -> boolean },
	now: () -> number,
	serverId: string,
	length: number, -- season length in seconds
	config: any,
	Season: any,
	Scores: any,
	Payout: any,
	Notices: any,
	Streak: any,
	log: (message: string) -> (),
}

export type Tally = typeof(setmetatable(
	{} :: {
		deps: Deps,
		known: { [number]: any }, -- the last stored value seen for each season id
		settling: { [number]: boolean },
		calling: { [number]: boolean },
	},
	Tally
))

function Tally.new(deps: Deps): Tally
	return setmetatable({ deps = deps, known = {}, settling = {}, calling = {} }, Tally)
end

function Tally.currentId(self: Tally): number?
	return self.deps.Season.idAt(self.deps.config.Epoch, self.deps.length, self.deps.now())
end

-- What record needs to know about a season: the stored value when this server has seen one,
-- otherwise the window the config gives, open.
function Tally.view(self: Tally, id: number): any
	local known = self.known[id]
	if known ~= nil then
		return known
	end
	local _, endsAt = self.deps.Season.window(self.deps.config.Epoch, self.deps.length, id)
	return { endsAt = endsAt, state = "open" }
end

-- Reads season/<id>. A read that raises is nil (the caller waits for the next poll).
function Tally.read(self: Tally, id: number): any?
	local ok, stored = pcall(function()
		return self.deps.seasons:GetAsync(self.deps.Season.key(id))
	end)
	if not ok then
		self.deps.log(`season {id} read failed: {tostring(stored)}`)
		return nil
	end
	if stored ~= nil then
		self.known[id] = stored
	end
	return stored
end

-- Creates season/<id> if it is missing and returns what is stored. Season.open is idempotent, so
-- any server may call it for any season, current or past.
function Tally.ensureOpen(self: Tally, id: number): any?
	local deps = self.deps
	local startsAt, endsAt = deps.Season.window(deps.config.Epoch, deps.length, id)
	local ok, result = pcall(function()
		return deps.seasons:UpdateAsync(deps.Season.key(id), function(current: any)
			local opened = deps.Season.open(current, id, startsAt, endsAt)
			return opened
		end)
	end)
	if not ok then
		deps.log(`season {id} open failed: {tostring(result)}`)
		return nil
	end
	if result == nil then
		return self:read(id) -- a cancelled update: read what is stored
	end
	self.known[id] = result
	return result
end

-- Keeps the current season's key present and this server's view of it fresh.
function Tally.tick(self: Tally): number?
	local id = self:currentId()
	if id ~= nil then
		self:ensureOpen(id)
	end
	return id
end

local function rules(self: Tally): any
	local config = self.deps.config
	return { mode = config.ScoreMode, maxPoints = config.MaxPointsPerCall, stat = config.ScoreStat }
end

-- Raises a player's season score. An in-memory change only (no yield): it reaches the store with
-- the next autosave or release.
function Tally.record(self: Tally, userId: number, points: any): (boolean, string?)
	local deps = self.deps
	local id = self:currentId()
	if id == nil then
		return false, "no_season"
	end
	local profile = deps.profiles.get(userId)
	if profile == nil then
		return false, "no_profile"
	end
	return deps.Scores.record(profile, id, points, self:view(id), deps.now(), rules(self))
end

-- Writes the player's current season score to the board (the cache). A failure is only logged.
function Tally.push(self: Tally, userId: number): boolean
	local id = self:currentId()
	local profile = self.deps.profiles.get(userId)
	if id == nil or profile == nil then
		return false
	end
	return self.deps.leaderboard:push(id, userId, self.deps.Scores.score(profile, id))
end

function Tally.busy(self: Tally, userId: number): boolean
	return self.settling[userId] == true or self.calling[userId] == true
end

return Tally
