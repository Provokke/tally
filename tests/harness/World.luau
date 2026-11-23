--!strict
-- A simulated world: one shared DataStore, one ordered store per season and one clock, with any
-- number of simulated servers over them. Each server has its own Faults, handles, profile layer,
-- Leaderboard and Tally, so a restart is a new server that reads only what the store holds.
--
-- Rules the harness keeps so a pass means something:
-- - every server name is used once, because it is the `closedBy` a spec reads;
-- - `restart` and `quiesce` mark the old servers dead first (the profile layer has no lease), so a
--   parked thread of an old server can never write again;
-- - Coins are counted from the store's records, never from a server's memory;
-- - settling until quiet is bounded, and hitting the bound is a failure that names the player whose
--   season is still unpaid.
local Config = require("../../src/shared/Config")
local Conservation = require("../fakes/Conservation")
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local FakeDataStore = require("../fakes/FakeDataStore")
local FakeOrderedDataStore = require("../fakes/FakeOrderedDataStore")
local Faults = require("../fakes/Faults")
local Leaderboard = require("../../src/server/Leaderboard")
local Notices = require("../../src/server/Notices")
local Payout = require("../../src/server/Payout")
local Scores = require("../../src/server/Scores")
local Season = require("../../src/server/Season")
local Streak = require("../../src/server/Streak")
local Tally = require("../../src/server/Tally")
local TestProfiles = require("../fakes/TestProfiles")

local World = {}
World.__index = World

World.USERS = { 1, 2, 3, 4 }
World.MAX_ROUNDS = 20
World.EPOCH = 1000

export type ServerOpts = {
	skew: number?, -- seconds added to this server's clock
	-- Replaces named pure modules (Season, Scores, Payout, Notices, Streak): a deliberately broken
	-- one, for a negative control.
	deps: any?,
	splitPayout: boolean?,
	-- Called with the key before each season write and each profile save (not counted as a write).
	gate: ((key: string) -> ())?,
}

export type Opts = {
	rankLag: number?, -- seconds before an ordered write is visible to a sorted read
	length: number?, -- season length in seconds
	config: any?, -- replaces the shipped config (with Epoch 1000) outright
	-- Options for the servers `quiesce` builds (a profile layer that never lets a save land).
	quiesceOpts: ServerOpts?,
}

-- One write the server made, numbered as its Faults numbers it. `op` is the operation that made
-- it and `kind` is `<op>:<season|profile|board>`.
export type Write = { n: number, key: string, op: string, kind: string }

local Server = {}
Server.__index = Server

export type Server = typeof(setmetatable(
	{} :: {
		name: string,
		faults: Faults.Faults,
		tally: any,
		profiles: TestProfiles.TestProfiles,
		leaderboard: any,
		logs: { string },
		trace: { Write },
		op: string,
		gate: ((key: string) -> ())?,
		clock: FakeClock.FakeClock,
		skew: number,
	},
	Server
))

function Server.now(self: Server): number
	return self.clock:now() + self.skew
end

function Server.join(self: Server, userId: number): any
	self.op = "join"
	return self.profiles:join(userId)
end

function Server.leave(self: Server, userId: number): boolean
	self.op = "leave"
	return self.profiles:leave(userId)
end

function Server.record(self: Server, userId: number, points: any): (boolean, string?)
	self.op = "record"
	return self.tally:record(userId, points)
end

function Server.tick(self: Server): number?
	self.op = "tick"
	return self.tally:tick()
end

function Server.push(self: Server, userId: number): boolean
	self.op = "push"
	return self.tally:push(userId)
end

-- The periodic save of a live profile.
function Server.autosave(self: Server, userId: number): boolean
	self.op = "autosave"
	local live = self.profiles:get(userId)
	if live == nil then
		return false
	end
	return self.profiles:save(userId, live)
end

function Server.settle(self: Server, userId: number): number
	self.op = "settle"
	return self.tally:settle(userId)
end

function Server.claim(self: Server, userId: number): (boolean, string?, number?)
	self.op = "claim"
	return self.tally:claimStreak(userId)
end

export type World = typeof(setmetatable(
	{} :: {
		opts: Opts,
		config: any,
		length: number,
		records: { [string]: any },
		clock: FakeClock.FakeClock,
		store: FakeDataStore.FakeDataStore,
		boards: { [number]: FakeOrderedDataStore.FakeOrderedDataStore },
		servers: { Server },
		names: { [string]: boolean },
		quiesces: number,
	},
	World
))

function World.new(opts: Opts?): World
	local o: Opts = opts or {}
	local length = o.length or 100
	local config: any = o.config
	if config == nil then
		config = Deep.copy(Config)
		config.Epoch = World.EPOCH
		config.SeasonLengthSeconds = length
	end
	local records: { [string]: any } = {}
	return setmetatable({
		opts = o,
		config = config,
		length = length,
		records = records,
		clock = FakeClock.new(1000),
		store = FakeDataStore.new(records),
		boards = {},
		servers = {},
		names = {},
		quiesces = 0,
	}, World)
end

-- The ordered store for a season (made on first use).
function World.board(self: World, id: number): FakeOrderedDataStore.FakeOrderedDataStore
	local board = self.boards[id]
	if board == nil then
		board = FakeOrderedDataStore.new(self.clock, self.opts.rankLag or 0)
		self.boards[id] = board
	end
	return board
end

-- A stored profile for a spec to seed: the unpaid season scores given by season id, the lifetime
-- stat equal to their sum (as record would have left it).
function World.newProfile(scores: { [number]: number }, coins: number?): any
	local seasons: any = {}
	local total = 0
	for id, score in scores do
		seasons[tostring(id)] = { score = score, rewarded = false }
		total += score
	end
	return {
		coins = coins or Config.StartingCoins,
		lifetime = if total > 0 then { points = total } else {},
		seasons = seasons,
		streak = { day = 0, count = 0, earned = 0 },
		notices = {},
	}
end

-- A fresh server with its own Faults. `name` must be new to this world.
function World.server(self: World, name: string, sopts: ServerOpts?): Server
	assert(not self.names[name], "server name used twice, so closedBy would not say who closed: " .. name)
	self.names[name] = true
	local o: ServerOpts = sopts or {}
	local faults = Faults.new()
	local clock = self.clock
	local config = self.config
	local s = setmetatable({
		name = name,
		faults = faults,
		logs = {},
		trace = {},
		op = "",
		gate = o.gate,
		clock = clock,
		skew = o.skew or 0,
	}, Server) :: any
	local function now(): number
		return s:now()
	end
	local function log(line: string)
		table.insert(s.logs, line)
	end
	local function traced(class: string, key: string)
		if not faults.dead then
			table.insert(s.trace, { n = faults.writes + 1, key = key, op = s.op, kind = `{s.op}:{class}` })
		end
	end
	local real = self.store:handle(faults)
	local function gated(key: string)
		local gate = s.gate
		if gate ~= nil and not faults.dead then
			gate(key)
		end
	end
	-- The season writes, which the gate sees before they land.
	local seasons = {
		UpdateAsync = function(_: any, key: string, transform: (any) -> any): any
			gated(key)
			traced("season", key)
			return real:UpdateAsync(key, transform)
		end,
		GetAsync = function(_: any, key: string, options: any?): any
			return real:GetAsync(key, options)
		end,
	}
	-- The profile writes, which the profile layer gates itself.
	local profileHandle = {
		UpdateAsync = function(_: any, key: string, transform: (any) -> any): any
			traced("profile", key)
			return real:UpdateAsync(key, transform)
		end,
		GetAsync = function(_: any, key: string, options: any?): any
			return real:GetAsync(key, options)
		end,
	}
	local function boardHandle(id: number): any
		local handle = self:board(id):handle(faults)
		local key = `board:{id}`
		return {
			SetAsync = function(_: any, k: string, value: number)
				traced("board", key)
				handle:SetAsync(k, value)
			end,
			UpdateAsync = function(_: any, k: string, transform: (number?) -> number?): number?
				traced("board", key)
				return handle:UpdateAsync(k, transform)
			end,
			GetAsync = function(_: any, k: string): number?
				return handle:GetAsync(k)
			end,
			GetSortedAsync = function(
				_: any,
				ascending: boolean,
				pageSize: number,
				min: number?,
				max: number?
			): any
				return handle:GetSortedAsync(ascending, pageSize, min, max)
			end,
		}
	end
	s.leaderboard = Leaderboard.new({
		store = boardHandle,
		now = now,
		size = config.BoardCacheSize,
		refreshSeconds = config.BoardRefreshSeconds,
		log = log,
	})
	s.profiles = TestProfiles.new(profileHandle, faults, {
		gate = gated,
		splitPayout = o.splitPayout,
		startCoins = config.StartingCoins,
		now = now,
	})
	local deps: any = {
		seasons = seasons,
		readOptions = { UseCache = false },
		leaderboard = s.leaderboard,
		profiles = {
			get = function(userId: number): any?
				return s.profiles:get(userId)
			end,
			save = function(userId: number, staked: any, _undo: (() -> ())?): boolean
				return s.profiles:save(userId, staked)
			end,
		},
		now = now,
		serverId = name,
		length = self.length,
		config = config,
		Season = Season,
		Scores = Scores,
		Payout = Payout,
		Notices = Notices,
		Streak = Streak,
		log = log,
	}
	for key, module in (o.deps or {}) :: any do
		deps[key] = module
	end
	s.tally = Tally.new(deps)
	table.insert(self.servers, s :: Server)
	return s :: Server
end

-- Stops a server for good: every later call through its handles raises CRASH.
function World.kill(_: World, s: Server)
	s.faults.dead = true
end

-- Kills `old` and builds a fresh server that reads only the store.
function World.restart(self: World, old: Server, name: string, sopts: ServerOpts?): Server
	self:kill(old)
	return self:server(name, sopts)
end

-- Writes a stored `Player_<id>` record directly (the starting state of a spec).
function World.seed(self: World, userId: number, data: any)
	self.records["Player_" .. userId] = { data = Deep.copy(data), schema = 1, savedAt = self.clock:now() }
end

-- Writes the season's ordered store directly: { [userId] = score }, visible after the rank lag.
function World.seedBoard(self: World, id: number, scores: { [number]: number })
	for userId, score in scores do
		self:board(id):write(tostring(userId), score)
	end
end

function World.currentId(self: World): number
	return Season.idAt(self.config.Epoch, self.length, self.clock:now()) or 0
end

-- The first old season still unpaid in the store, as text naming the player ("" when none).
function World.unpaid(self: World): string
	local users: { number } = {}
	for key in self.records do
		local id = string.match(key, "^Player_(%d+)$")
		if id ~= nil then
			table.insert(users, tonumber(id) :: number)
		end
	end
	table.sort(users)
	local current = self:currentId()
	for _, userId in users do
		local seasons = self.records["Player_" .. userId].data.seasons or {}
		local keys: { string } = {}
		for key in seasons do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			local entry = seasons[key]
			local id = tonumber(key)
			if id ~= nil and id < current and entry.score > 0 and not entry.rewarded then
				return `player {userId} season {key} is still unpaid (rewarded={tostring(entry.rewarded)})`
			end
		end
	end
	return ""
end

-- The records with the save time left out, so a round that rewrites the same data is unchanged.
local function stable(records: { [string]: any }): { [string]: any }
	local out: { [string]: any } = {}
	for key, record in records do
		if string.match(key, "^Player_%d+$") ~= nil then
			out[key] = Deep.copy(record.data)
		else
			out[key] = Deep.copy(record)
		end
	end
	return out
end

-- Every server is killed (a restart of the whole fleet), the clock moves on an hour, and a fresh
-- server has every user join, tick, settle and leave until a round pays nothing and changes
-- nothing. Returns false and a reason when it is still working after MAX_ROUNDS, or when quiet
-- leaves a season unpaid in the store; the reason names the player.
function World.quiesce(self: World): (boolean, string?)
	for _, s in self.servers do
		self:kill(s)
	end
	self.clock:advance(3600)
	self.quiesces += 1
	local q = self:server("Q" .. self.quiesces, self.opts.quiesceOpts)
	for _ = 1, World.MAX_ROUNDS do
		local before = stable(self.records)
		local paid = 0
		for _, userId in World.USERS do
			q:join(userId)
			q:tick()
			paid += q:settle(userId)
			q:leave(userId)
		end
		if paid == 0 and Deep.equal(before, stable(self.records)) then
			local why = self:unpaid()
			if why ~= "" then
				return false, why
			end
			return true, nil
		end
	end
	local why = self:unpaid()
	return false,
		`not quiet after {World.MAX_ROUNDS} rounds; {if why ~= "" then why else "records still changing"}`
end

-- The conservation check over the store's records: every Coin is the start plus season rewards
-- (each from a closed season, paid once) plus the streak, and every old scored season is paid.
function World.check(self: World, startCoins: number): (boolean, string?)
	local audited: any = {}
	for key, record in self.records do
		local id = string.match(key, "^Player_(%d+)$")
		if id ~= nil then
			audited["profile/" .. id] = record.data
		else
			audited[key] = record
		end
	end
	local start: { [number]: number } = {}
	for _, userId in World.USERS do
		start[userId] = startCoins
	end
	return Conservation.check(audited, start, { currentId = self:currentId(), mode = "sum" })
end

return World
