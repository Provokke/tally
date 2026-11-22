--!strict
-- What the client may ask the server for. A factory: everything arrives as a dependency, so the
-- checks can be tested without remotes.
--
-- Clients send intent only: an action name, and for the board a page number. Nothing a client sends
-- is a score, a Coin amount or a season: points come from the game's own server code through
-- TallyRecord, and an action that is not claim_streak or board_page is dropped. Every call is
-- checked with Validate and then the per-player rate limiter before anything else. A call that
-- fails either, comes from a player with no saveable session, or is not one of the two actions,
-- is dropped and counted. A call the rules refuse (already_claimed and so on) is not counted and
-- logs nothing, as that is an ordinary answer: it goes to the player with the next Sync, which
-- carries the real state.
--
-- Store budget: a claim saves the profile, so it also spends from a second, slower limiter by
-- what it costs the store, and a loop of claims cannot use up the server's write budget. A call
-- over it is answered with "slow_down". board_page reads only the per-server board cache and is
-- not charged. A client can't start a settle or a season read at all: those run from the poll in
-- the entry script, once per SettleSeconds.
--
-- Busy guard: a claim yields (it saves the profile). While it does, and while a settle runs for
-- the player, any other call from that player is answered "busy", so one player's calls never
-- interleave. The entry script also waits on `busy` before it releases a session on leave or
-- shutdown.
--
-- What Tally returns is mapped to one result, { action, ok, reason?, reward? }, handed to `sync`:
--   claim_streak   true and the Coins, or false and the reason
--   board_page     true (the page is remembered for the next Sync)
-- A call that throws is logged on one line and counted, and the player is still synced.
local Handlers = {}
Handlers.__index = Handlers

export type Result = { action: string, ok: boolean, reason: string?, reward: number? }

export type Deps = {
	validate: any, -- the Validate module
	limiter: any, -- a RateLimiter, keyed by UserId
	storeLimiter: any, -- a second RateLimiter for calls that touch the DataStore, keyed by UserId
	storeCost: { [string]: number }, -- what each action spends from storeLimiter
	config: any,
	tally: any, -- a Tally
	allowed: (userId: number) -> boolean, -- the player has a session that would be saved
	setPage: (userId: number, page: number) -> (), -- the board page this player is looking at
	sync: (userId: number, result: Result?) -> (), -- sends one player their current state
	log: (message: string) -> (), -- one line per call that threw
}

export type Handlers = typeof(setmetatable(
	{} :: { deps: Deps, dropped: number, running: { [number]: boolean } },
	Handlers
))

local ACTIONS: { [string]: boolean } = { claim_streak = true, board_page = true }
local MAX_PAGE = 100

function Handlers.new(deps: Deps): Handlers
	return setmetatable({ deps = deps, dropped = 0, running = {} }, Handlers)
end

local function valid(deps: Deps, action: any, a: any): boolean
	local v = deps.validate
	if not (v.isString(action, 16) and v.isOneOf(action, ACTIONS)) then
		return false
	end
	if action == "claim_streak" then
		return a == nil
	end
	return v.isInteger(a, 1, MAX_PAGE)
end

-- Whether a call for this player is still running, here or inside Tally.
function Handlers.busy(self: Handlers, userId: number): boolean
	return self.running[userId] == true or self.deps.tally:busy(userId) == true
end

local function run(deps: Deps, userId: number, action: string, a: any): Result?
	if action == "board_page" then
		deps.setPage(userId, a)
		return { action = action, ok = true }
	end
	local done, reason, reward = deps.tally:claimStreak(userId)
	if done ~= true and reason == "busy" then
		return nil
	end
	return { action = action, ok = done == true, reason = reason, reward = reward }
end

-- One call from a client. Returns nothing and never throws.
function Handlers.handle(self: Handlers, userId: number, action: any, a: any)
	local deps = self.deps
	local ok = pcall(function()
		if not valid(deps, action, a) or not deps.limiter:take(userId) then
			self.dropped += 1
			return
		end
		if not deps.allowed(userId) then
			self.dropped += 1
			return
		end
		if self:busy(userId) then
			-- Another call, or the settle, holds this player's lock: say so rather than go quiet.
			self.dropped += 1
			deps.sync(userId, { action = action, ok = false, reason = "busy" })
			return
		end
		local cost = deps.storeCost[action]
		if cost ~= nil and not deps.storeLimiter:take(userId, cost) then
			-- Too many store operations lately: tell the player rather than go quiet.
			self.dropped += 1
			deps.sync(userId, { action = action, ok = false, reason = "slow_down" })
			return
		end
		self.running[userId] = true
		local done, result = pcall(run, deps, userId, action, a)
		self.running[userId] = nil
		if not done then
			self.dropped += 1
			pcall(deps.log, `request failed for {userId} ({action}): {tostring(result)}`)
			deps.sync(userId, nil)
			return
		end
		if result == nil then
			self.dropped += 1 -- Tally was busy with something else for this player
			deps.sync(userId, { action = action, ok = false, reason = "busy" })
			return
		end
		deps.sync(userId, result)
	end)
	if not ok then
		self.dropped += 1
	end
end

return Handlers
