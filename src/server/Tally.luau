--!strict
-- The season service: which season is current, opening its key, recording scores and pushing
-- them to the board. It orders reads and writes; every decision comes from the pure modules,
-- which are passed in (this file requires nothing).
local Tally = {}
Tally.__index = Tally

export type Deps = {
	seasons: any, -- a DataStore handle: UpdateAsync and GetAsync
	-- The options every season read passes to GetAsync: a DataStoreGetOptions with UseCache false,
	-- so a read that follows a close or a cancelled write is never a stale local copy.
	readOptions: any?,
	leaderboard: any, -- a Leaderboard
	-- save writes the profile the caller changed. `undo`, when given, is run by the save, under the
	-- session's lock, if the write does not land, so no other write can store the change first.
	profiles: {
		get: (userId: number) -> any?,
		save: (userId: number, staked: any, undo: (() -> ())?) -> boolean,
	},
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
		closing: { [number]: boolean }, -- seasons this server is closing right now
		boardOutage: { [number]: { first: number, last: number } }, -- a season's podium read outage: first and latest failed attempt
		mismatched: { [number]: boolean }, -- seasons whose stored window is not the config's
	},
	Tally
))

function Tally.new(deps: Deps): Tally
	return setmetatable({
		deps = deps,
		known = {},
		settling = {},
		calling = {},
		closing = {},
		boardOutage = {},
		mismatched = {},
	}, Tally)
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

-- Reads season/<id> without the local cache. (false) when the read raised, else (true, the stored
-- value or nil when the key is missing).
local function fetch(self: Tally, id: number): (boolean, any)
	local ok, stored = pcall(function()
		return self.deps.seasons:GetAsync(self.deps.Season.key(id), self.deps.readOptions)
	end)
	if not ok then
		self.deps.log(`season {id} read failed: {tostring(stored)}`)
		return false, nil
	end
	return true, stored
end

-- What the mismatch log shows of a stored value: its window, or the value itself when it is not a table.
local function describe(stored: any): string
	if type(stored) ~= "table" then
		return `{typeof(stored)} {tostring(stored)}`
	end
	return `{tostring(stored.startsAt)}-{tostring(stored.endsAt)}`
end

-- Takes a stored season as this server's view of it, unless the window it holds is not the one the
-- config gives. That happens when SeasonLengthSeconds or Epoch is changed on a live game: the ids
-- then point at keys made under the old numbering. Such a key is never used: nothing is scored into
-- it and nothing is paid from it. Logged once per season.
local function accept(self: Tally, id: number, stored: any): any?
	local deps = self.deps
	local startsAt, endsAt = deps.Season.window(deps.config.Epoch, deps.length, id)
	if not deps.Season.matches(stored, startsAt, endsAt) then
		if not self.mismatched[id] then
			self.mismatched[id] = true
			deps.log(
				`season {id} is stored as {describe(stored)} but the config says {startsAt}-{endsAt}: `
					.. "the season does not match, so it is refused. SeasonLengthSeconds or Epoch was changed on a live game; "
					.. "see the README before changing either."
			)
		end
		return nil
	end
	self.mismatched[id] = nil
	self.known[id] = stored
	return stored
end

-- Reads season/<id>. A read that raises is nil (the caller waits for the next poll), and so is a
-- key that is missing or does not match the config's window.
function Tally.read(self: Tally, id: number): any?
	local ok, stored = fetch(self, id)
	if not ok or stored == nil then
		return nil
	end
	return accept(self, id, stored)
end

-- Makes sure season/<id> exists and returns what is stored. The key is read first and written only
-- when it is missing: Season.open is idempotent, so a rival that creates it first just wins.
function Tally.ensureOpen(self: Tally, id: number): any?
	local deps = self.deps
	local read, stored = fetch(self, id)
	if not read then
		return nil
	end
	if stored ~= nil then
		return accept(self, id, stored)
	end
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
	return accept(self, id, result)
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
	if self.mismatched[id] then
		return false, "season_mismatch"
	end
	local profile = deps.profiles.get(userId)
	if profile == nil then
		return false, "no_profile"
	end
	return deps.Scores.record(profile, id, points, self:view(id), deps.now(), scoreRules(self))
end

-- Whether the season before the current one is still pushed: a score made in its last push
-- interval is only in memory when the clock turns over, so until the season is known closed (and
-- past the close grace) the push carries it to that season's board. A paid season has been closed.
local function pushesPrevious(self: Tally, id: number, profile: any): boolean
	local deps = self.deps
	local entry = profile.seasons[deps.Scores.key(id)]
	if entry == nil or entry.rewarded then
		return false
	end
	local known = self.known[id]
	if
		known ~= nil
		and known.state == "closed"
		and deps.now() >= known.endsAt + deps.config.CloseGraceSeconds
	then
		return false
	end
	return true
end

-- Writes the player's current season score to the board (the cache), and the previous season's
-- while it may still be waiting for its close. A failure is only logged.
function Tally.push(self: Tally, userId: number): boolean
	local deps = self.deps
	local id = self:currentId()
	local profile = deps.profiles.get(userId)
	if id == nil or profile == nil then
		return false
	end
	local ok = deps.leaderboard:push(id, userId, deps.Scores.score(profile, id))
	local previous = id - 1
	if previous >= 1 and pushesPrevious(self, previous, profile) then
		ok = deps.leaderboard:push(previous, userId, deps.Scores.score(profile, previous)) and ok
	end
	return ok
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

local function closeOnce(self: Tally, id: number): any?
	local deps = self.deps
	local podium, why = deps.leaderboard:read(id, deps.config.PodiumSize)
	if podium == nil then
		-- A board that can't be read now may be back on the next settle, so wait rather than freeze
		-- an empty podium for everyone. Only once reads have kept failing for PodiumWaitSeconds, from
		-- the first failed attempt of this outage on this server, does the season close without one,
		-- so a board that never returns can't block rewards. (Measured from the season's end, a first
		-- player who joined hours late would freeze an empty podium on one failed read.) An outage
		-- is a run of failed attempts no more than twice SettleSeconds apart: a gap longer than that
		-- (the player who failed has left, the board came back and went again) starts a new one, so
		-- an old timer can't make one new failure close the season. Whatever the outage, a season
		-- is closed without a podium once PodiumMaxSeconds have passed since its end, so players
		-- are eventually paid.
		local now = deps.now()
		local outage = self.boardOutage[id]
		if outage == nil or now - outage.last > 2 * deps.config.SettleSeconds then
			-- Logged once per outage, not on every poll for every player.
			outage = { first = now, last = now }
			self.boardOutage[id] = outage
			deps.log(`podium read failed for season {id}, waiting: {tostring(why)}`)
		end
		outage.last = now
		local _, endsAt = deps.Season.window(deps.config.Epoch, deps.length, id)
		local waiting = now - outage.first < deps.config.PodiumWaitSeconds
		local pastMax = closeClock(self) >= endsAt + deps.config.PodiumMaxSeconds
		if waiting and not pastMax then
			return nil
		end
		deps.log(`podium read failed for season {id}, closing without one: {tostring(why)}`)
		podium = {}
	else
		self.boardOutage[id] = nil
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
	return accept(self, id, result)
end

-- One close per season at a time on this server: while one settle is in the board read or the
-- write, the other players' settles leave the season alone (nil, as a wait) and are paid from the
-- stored close on their next settle, rather than each reading the board and writing a close.
local function closeSeason(self: Tally, id: number): any?
	if self.closing[id] then
		return nil
	end
	self.closing[id] = true
	local ok, result = pcall(closeOnce, self, id)
	self.closing[id] = nil
	if not ok then
		error(result, 0)
	end
	return result
end

-- One in-memory change (Coins, the paid flag, the notice), then one save bound to this profile.
-- A save that fails rolls the change back relative to the current values.
local function applyPayout(self: Tally, userId: number, profile: any, key: string, decision: any): boolean
	local deps = self.deps
	local applied = deps.Payout.apply(profile, key, decision)
	local added = deps.Notices.add(profile, decision.text, deps.now(), deps.config.NoticeCap)
	local undone = false
	local function undo()
		if undone then
			return
		end
		undone = true
		deps.Payout.undo(profile, key, applied)
		deps.Notices.remove(profile, added)
	end
	local saved = deps.profiles.save(userId, profile, undo)
	if not saved then
		undo() -- already done under the lock when the save ran; this covers a save refused before it
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
		if season == nil and self.mismatched[id] then
			continue -- its stored window is not the config's: nothing to open, close or pay
		end
		for _ = 1, 4 do
			local entry = profile.seasons[key]
			local decision = deps.Payout.decide(entry, season, id, currentId, userId, closeClock(self), rules)
			if decision.action == "open" then
				season = self:ensureOpen(id)
			elseif decision.action == "close" then
				season = closeSeason(self, id)
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

local STREAK_FIELDS = { "day", "count", "earned" }

-- One in-memory change (the new streak, the Coins, the notice), then one save bound to this
-- profile. A save that fails rolls the change back relative to the current values: the Coins are
-- subtracted, and a streak field is put back only if it still holds what this claim set, so a
-- Coin or a field changed while the save was in flight is kept.
local function claim(self: Tally, userId: number): (boolean, string?, number?)
	local deps = self.deps
	local profile = deps.profiles.get(userId)
	if profile == nil then
		return false, "no_profile", nil
	end
	local now = deps.now()
	local claimed, why = deps.Streak.claim(profile.streak, deps.Streak.dayOf(now), deps.config.StreakRewards)
	if claimed == nil then
		return false, why, nil
	end
	local before = profile.streak
	local applied = table.clone(claimed.streak)
	profile.streak = claimed.streak
	profile.coins += claimed.reward
	local added = deps.Notices.add(
		profile,
		`Streak day {claimed.streak.count}: {claimed.reward} Coins claimed.`,
		now,
		deps.config.NoticeCap
	)
	local undone = false
	local function undo()
		if undone then
			return
		end
		undone = true
		for _, field in STREAK_FIELDS do
			if before[field] ~= applied[field] and profile.streak[field] == applied[field] then
				profile.streak[field] = before[field]
			end
		end
		profile.coins -= claimed.reward
		deps.Notices.remove(profile, added)
	end
	if not deps.profiles.save(userId, profile, undo) then
		undo() -- already done under the lock when the save ran; this covers a save refused before it
		deps.log(`streak save failed for {userId}`)
		return false, "save_failed", nil
	end
	return true, nil, claimed.reward
end

-- Claims the player's daily streak: the Coins, the new streak and a notice land in one save.
-- (true, nil, reward) on success, else (false, reason).
function Tally.claimStreak(self: Tally, userId: number): (boolean, string?, number?)
	if self.calling[userId] then
		return false, "busy", nil
	end
	self.calling[userId] = true
	local ok, done, why, reward = pcall(claim, self, userId)
	self.calling[userId] = nil
	if not ok then
		self.deps.log(`streak claim failed for {userId}: {tostring(done)}`)
		return false, "error", nil
	end
	return done, why, reward
end

return Tally
