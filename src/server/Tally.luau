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

local function scoreRules(self: Tally): any
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
	return deps.Scores.record(profile, id, points, self:view(id), deps.now(), scoreRules(self))
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

local function payoutRules(self: Tally): any
	local config = self.deps.config
	return { tiers = config.Tiers, podiumBonus = config.PodiumBonus }
end

-- Reads the top of the board (uncached) and writes the close through UpdateAsync. The transform
-- is pure, so a re-run or a rival close is safe: the first close wins and everyone reads it.
-- Returns what is stored afterwards: the close we wrote, a rival's close, or the still-open key
-- when this server's clock is behind (not_ended), or nil when the write raised (wait).
-- The clock a close is judged by: CloseGraceSeconds behind this server's, so a server whose clock
-- runs a little fast can't close a season before it has really ended.
local function closeClock(self: Tally): number
	return self.deps.now() - self.deps.config.CloseGraceSeconds
end

local function closeSeason(self: Tally, id: number, season: any): any?
	local deps = self.deps
	local podium, why = deps.leaderboard:read(id, deps.config.PodiumSize)
	if podium == nil then
		-- A board that can't be read now may be back on the next settle, so wait rather than freeze
		-- an empty podium for everyone. Only once it has stayed unreadable PodiumWaitSeconds past the
		-- end does the season close without one, so a board that never returns can't block rewards.
		if closeClock(self) < season.endsAt + deps.config.PodiumWaitSeconds then
			deps.log(`podium read failed for season {id}, waiting: {tostring(why)}`)
			return nil
		end
		deps.log(`podium read failed for season {id}, closing without one: {tostring(why)}`)
		podium = {}
	end
	local now = closeClock(self)
	local ok, result = pcall(function()
		return deps.seasons:UpdateAsync(deps.Season.key(id), function(current: any)
			local closed = deps.Season.close(current, now, podium, deps.serverId)
			return closed
		end)
	end)
	if not ok then
		deps.log(`season {id} close failed: {tostring(result)}`)
		return nil
	end
	if result == nil then
		return self:read(id)
	end
	self.known[id] = result
	return result
end

-- One in-memory change (Coins, the paid flag, the notice), then one save bound to this profile.
-- A save that fails rolls the change back relative to the current values.
local function applyPayout(self: Tally, userId: number, profile: any, key: string, decision: any): boolean
	local deps = self.deps
	local undo = deps.Payout.apply(profile, key, decision)
	local added = deps.Notices.add(profile, decision.text, deps.now(), deps.config.NoticeCap)
	local saved = deps.profiles.save(userId, profile)
	if not saved then
		deps.Payout.undo(profile, key, undo)
		deps.Notices.remove(profile, added)
		deps.log(`payout save failed for {userId}`)
		return false
	end
	return true
end

local function settleSeasons(self: Tally, userId: number): number
	local deps = self.deps
	local profile = deps.profiles.get(userId)
	local currentId = self:currentId()
	if profile == nil or currentId == nil then
		return 0
	end
	local rules = payoutRules(self)
	local ids: { number } = {}
	for key, entry in profile.seasons do
		local id = tonumber(key)
		if id ~= nil and id < currentId and not entry.rewarded and entry.score > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local paid = 0
	for _, id in ids do
		local key = deps.Scores.key(id)
		local season = self.known[id]
		if season == nil or season.state ~= "closed" then
			season = self:read(id)
		end
		for _ = 1, 4 do
			local entry = profile.seasons[key]
			local decision = deps.Payout.decide(entry, season, id, currentId, userId, closeClock(self), rules)
			if decision.action == "open" then
				season = self:ensureOpen(id)
			elseif decision.action == "close" then
				season = closeSeason(self, id, season)
			elseif decision.action == "pay" then
				if not applyPayout(self, userId, profile, key, decision) then
					return paid
				end
				paid += 1
				break
			else
				break
			end
			if season == nil then
				break
			end
		end
	end
	return paid
end

function Tally.settle(self: Tally, userId: number): number
	if self.settling[userId] then
		return 0
	end
	self.settling[userId] = true
	local paid = 0
	local ok, err = pcall(function()
		paid = settleSeasons(self, userId)
	end)
	self.settling[userId] = nil
	if not ok then
		self.deps.log(`settle failed for {userId}: {tostring(err)}`)
	end
	return paid
end

return Tally
