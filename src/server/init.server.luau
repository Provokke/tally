--!strict
-- Tally server entry. This is where services, remotes, the DataStores and the ordered stores are
-- touched. The rules themselves live in the modules next to it and are covered by the Lune tests.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Tally")
local Config = require(Shared:WaitForChild("Config"))
local BoardLogic = require(Shared:WaitForChild("BoardLogic"))
local ConfigCheck = require(Shared:WaitForChild("ConfigCheck"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local Validate = require(Shared:WaitForChild("Validate"))

local DemoSeed = require(script.DemoSeed)
local Handlers = require(script.Handlers)
local Lease = require(script.Data.Lease)
local Leaderboard = require(script.Leaderboard)
local MemoryOrderedStore = require(script.Data.MemoryOrderedStore)
local MemoryStore = require(script.Data.MemoryStore)
local Migrations = require(script.Data.Migrations)
local Notices = require(script.Notices)
local Payout = require(script.Payout)
local Profile = require(script.Data.Profile)
local Scores = require(script.Scores)
local Season = require(script.Season)
local Sessions = require(script.Sessions)
local Steps = require(script.Data.Steps)
local Store = require(script.Data.Store)
local Streak = require(script.Streak)
local Tally = require(script.Tally)

local configOk, configProblem = ConfigCheck.check(Config)
if not configOk then
	warn("[Tally] config problem: " .. tostring(configProblem))
	warn("[Tally] not starting until the config is fixed.")
	return
end

local function log(message: string)
	warn("[Tally] " .. message)
end

-- Data stores. Studio uses in-memory tables unless ServerStorage has TallyUseDataStore = true. The
-- ordered stores follow the data stores: an unpublished place can't reach either real service.
local useRealStore = not RunService:IsStudio() or ServerStorage:GetAttribute("TallyUseDataStore") == true
local playerStore: any
local seasonStore: any
local ordered: (seasonId: number) -> any
if useRealStore then
	local acquired, problem = pcall(function()
		playerStore = DataStoreService:GetDataStore(Config.DataStoreName)
		seasonStore = DataStoreService:GetDataStore(Config.SeasonStoreName)
		ordered = function(seasonId: number): any
			return DataStoreService:GetOrderedDataStore(Config.BoardStorePrefix .. seasonId)
		end
	end)
	if not acquired then
		-- In Studio an unpublished place has no real stores: carry on in memory rather than stop. A
		-- live server never falls back, as it would run without saving.
		if not RunService:IsStudio() then
			error(problem, 0)
		end
		warn(
			"Tally: the real data stores aren't available (publish the place, or turn off TallyUseDataStore); using in-memory stores, nothing will be saved"
		)
		useRealStore = false
	end
end
if not useRealStore then
	playerStore = MemoryStore.new()
	seasonStore = MemoryStore.new()
	local boards: { [number]: any } = {}
	ordered = function(seasonId: number): any
		if boards[seasonId] == nil then
			boards[seasonId] = MemoryOrderedStore.new()
		end
		return boards[seasonId]
	end
	print(
		"[Tally] Studio: using in-memory stores. Set ServerStorage attribute TallyUseDataStore to use the real ones."
	)
end

-- Every Studio play test gets its own id, so a lease left behind by a crashed or parallel test
-- reads as someone else's (and runs out) rather than as ours.
local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local profile = Profile.new({ startingCoins = Config.StartingCoins })

local store = Store.new({
	dataStore = playerStore,
	lease = Lease,
	migrations = Migrations,
	clock = os.time,
	wait = task.wait,
	budget = function(_kind: string): number
		if not useRealStore then
			return 100 -- the in-memory store has no request budget
		end
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end,
	jobId = jobId,
	nonce = function(): string
		return HttpService:GenerateGUID(false)
	end,
	resume = function(thread: thread)
		task.spawn(thread)
	end,
	leaseSeconds = Config.LeaseSeconds,
	retries = Config.LoadRetries,
	retryBase = Config.RetryBaseSeconds,
	schema = Config.SchemaVersion,
	steps = Steps,
	defaultData = profile.defaultData,
	encode = profile.encode,
	decode = profile.decode,
	log = log,
})

-- The season length. A Studio demo shortens it so a season can be watched start to finish.
local length = if RunService:IsStudio() and ServerStorage:GetAttribute("TallyDemoSeason") == true
	then Config.DemoSeasonSeconds
	else Config.SeasonLengthSeconds

-- Remotes. Request is client to server (intent only, connected with the handlers), Sync is server
-- to client.
local request = Instance.new("RemoteEvent")
request.Name = "Request"
request.Parent = Shared
local sync = Instance.new("RemoteEvent")
sync.Name = "Sync"
sync.Parent = Shared

local sessions: any
local tally: any
local handlers: any
local leaderboard: any

-- The board page each player is looking at. The client asks for a page with board_page and the
-- next Sync carries it. Cleared when the player leaves.
local pages: { [number]: number } = {}

-- The last notice each player was sent, so a Sync carries only what is new. Notices are tables
-- in the profile and the oldest are dropped from the front, so the last one sent is found by
-- identity. If it has been dropped, everything left is new.
local lastNotice: { [number]: any } = {}

local function newNotices(userId: number, notices: { any }): { any }
	local start = 1
	local last = lastNotice[userId]
	if last ~= nil then
		local at = table.find(notices, last)
		if at ~= nil then
			start = at + 1
		end
	end
	local out = {}
	for i = start, #notices do
		table.insert(out, { text = notices[i].text, at = notices[i].at })
	end
	if #notices > 0 then
		lastNotice[userId] = notices[#notices]
	end
	return out
end

-- What one player sees: their Coins, the current season and their score and rank in it, the cached
-- top of the board and their streak, the notices since the last Sync, and the answer to the call
-- that caused it. Sent on join and after every call. A player with no session or no current
-- season is not synced. The board comes from the per-server cache, so the number of Syncs never
-- sets the number of ordered reads.
local function syncPlayer(userId: number, result: any?)
	local player = Players:GetPlayerByUserId(userId)
	local session = sessions:get(userId)
	local id = tally:currentId()
	if player == nil or session == nil or id == nil then
		return
	end
	local data = session.data
	local now = os.time()
	local view = tally:view(id)
	local score = Scores.score(data, id)
	local top = leaderboard:top(id)
	local entries = {}
	for _, entry in top do
		table.insert(entries, { userId = entry.userId, score = entry.score })
	end
	local payload: { [string]: any } = {
		coins = data.coins,
		serverNow = now,
		season = {
			id = id,
			endsAt = view.endsAt,
			state = if view.state == "closed" then "closed" else "open",
		},
		score = score,
		rank = BoardLogic.estimateRank(entries, Config.BoardCacheSize, score),
		board = { page = pages[userId] or 1, entries = entries },
		streak = Streak.state(data.streak, Streak.dayOf(now), Config.StreakRewards),
		notices = newNotices(userId, data.notices),
		result = result,
	}
	pcall(function()
		sync:FireClient(player, payload)
	end)
end

-- Settles the seasons a player has finished and syncs them if any was paid. Never throws.
local function settlePlayer(userId: number)
	local ok, paid = pcall(function()
		return tally:settle(userId)
	end)
	if not ok then
		log(`settle failed for {userId}: {tostring(paid)}`)
		return
	end
	if paid ~= nil and paid > 0 then
		syncPlayer(userId, nil)
	end
end

-- The Studio demo seed: pretend players on the board and one finished season for the player, so the
-- first settle pays a reward. Only in Studio, only over the in-memory stores, only with the
-- TallyDemoSeed attribute, and once per player. A failure is logged, never raised.
local demoDone: { [number]: boolean } = {}

local function seedDemo(userId: number, session: any)
	if
		useRealStore
		or not RunService:IsStudio()
		or ServerStorage:GetAttribute("TallyDemoSeed") ~= true
		or demoDone[userId]
	then
		return
	end
	demoDone[userId] = true
	local ok, err = pcall(function()
		local id = tally:currentId()
		if id == nil then
			return
		end
		local plan = DemoSeed.plan(userId, id)
		for boardId, rows in plan.board do
			for key, score in rows do
				ordered(boardId):SetAsync(key, score)
			end
		end
		for key, entry in plan.profile do
			if session.data.seasons[key] == nil then
				session.data.seasons[key] = entry
			end
		end
	end)
	if not ok then
		log(`demo seed failed for {userId}: {tostring(err)}`)
	end
end

-- A session went live: settle what it holds and show it, each in its own thread, as both yield (the
-- settle on the stores, the Sync on the board's cached read) and the join is not held up by either.
-- The settle starts first and the Sync does not wait for it, so the player sees their state before
-- a slow settle finishes.
local function onSessionReady(userId: number, session: any)
	seedDemo(userId, session)
	task.spawn(settlePlayer, userId)
	task.spawn(syncPlayer, userId, nil)
end

sessions = Sessions.new({
	store = store,
	keyFor = function(userId: number): string
		return "Player_" .. userId
	end,
	present = function(player: any): boolean
		return player.Parent ~= nil
	end,
	kick = function(player: any, message: string)
		player:Kick(message)
	end,
	playerOf = function(userId: number): any
		return Players:GetPlayerByUserId(userId)
	end,
	ready = onSessionReady,
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	wait = function(seconds: number)
		task.wait(seconds)
	end,
	clock = os.clock,
	closeSeconds = Config.CloseTimeoutSeconds,
	log = log,
	-- A release on leave or shutdown waits for a score, settle or streak call that is still running.
	inUse = function(userId: number): boolean
		return handlers ~= nil and handlers:busy(userId)
	end,
})

leaderboard = Leaderboard.new({
	store = ordered,
	now = os.time,
	size = Config.BoardCacheSize,
	refreshSeconds = Config.BoardRefreshSeconds,
	log = log,
})

tally = Tally.new({
	seasons = seasonStore,
	leaderboard = leaderboard,
	profiles = {
		-- Only a session that would be saved may change anything: a read-only or lost one has no
		-- profile here, so scoring refuses it.
		get = function(userId: number): any
			local session = sessions:writableSession(userId)
			return if session ~= nil then session.data else nil
		end,
		-- Saves only the profile the caller changed. If the player has left and come back since,
		-- that table belongs to a dead session, so saving "their" session would write a different
		-- profile than the one the caller changed.
		save = function(userId: number, staked: any, undo: (() -> ())?): boolean
			local session = sessions:writableSession(userId)
			if session == nil or session.data ~= staked then
				return false
			end
			return sessions:saveNow(userId, undo)
		end,
	},
	now = os.time,
	serverId = jobId,
	length = length,
	config = Config,
	Season = Season,
	Scores = Scores,
	Payout = Payout,
	Notices = Notices,
	Streak = Streak,
	log = log,
})

handlers = Handlers.new({
	validate = Validate,
	limiter = RateLimiter.new(Config.Limits.BurstPerPlayer, Config.Limits.RefillPerSecond, os.clock),
	storeLimiter = RateLimiter.new(
		Config.Limits.StoreBurstPerPlayer,
		Config.Limits.StoreOpsPerMinute / 60,
		os.clock
	),
	storeCost = Config.Limits.StoreCost,
	config = Config,
	tally = tally,
	allowed = function(userId: number): boolean
		return sessions:writableSession(userId) ~= nil
	end,
	setPage = function(userId: number, page: number)
		pages[userId] = page
	end,
	sync = syncPlayer,
	log = log,
})

-- Requests from clients: intent only (claim_streak, board_page). Nothing here changes a score.
request.OnServerEvent:Connect(function(player: Player, action: any, a: any)
	local ok, err = pcall(handlers.handle, handlers, player.UserId, action, a)
	if not ok then
		log("request error: " .. tostring(err))
	end
end)

-- Scoring for the game's own server code. Only server code can reach ServerStorage, and no remote
-- accepts points: the game calls this from its own scripts with a number it decided.
local record = Instance.new("BindableFunction")
record.Name = "TallyRecord"
record.OnInvoke = function(player: Player, points: number): (boolean, string?)
	local ok, accepted, reason = pcall(function()
		return tally:record(player.UserId, points)
	end)
	if not ok then
		log("record error: " .. tostring(accepted))
		return false, "error"
	end
	return accepted, reason
end
record.Parent = ServerStorage

-- Sessions
local function onPlayerAdded(player: Player)
	sessions:join(player.UserId, player)
end

local function onPlayerRemoving(player: Player)
	local userId = player.UserId
	handlers.deps.limiter:forget(userId)
	handlers.deps.storeLimiter:forget(userId)
	pages[userId] = nil
	lastNotice[userId] = nil
	-- Push the score first: it reads the live session, which the leave then releases.
	task.spawn(tally.push, tally, userId)
	sessions:leave(userId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

-- Autosave. A session that has lost its lease is kicked rather than allowed to carry on unsaved.
task.spawn(function()
	while true do
		task.wait(Config.AutosaveSeconds)
		sessions:saveAll()
	end
end)

-- Season tick: the current season's key exists, and this server sees a close made by another. The
-- first tick runs at once, in the loop's own thread, so a slow store can't hold up the rest of the
-- script (the shutdown hook below).
task.spawn(function()
	while true do
		tally:tick()
		task.wait(Config.SeasonTickSeconds)
	end
end)

-- Settle poll: a season ends while players are in the server, so every player with a writable
-- session is settled every SettleSeconds, not only at the join.
task.spawn(function()
	while true do
		task.wait(Config.SettleSeconds)
		for _, player in Players:GetPlayers() do
			local userId = player.UserId
			if sessions:writableSession(userId) ~= nil then
				task.spawn(settlePlayer, userId)
			end
		end
	end
end)

-- Board push: every player's season score goes to the ordered store.
task.spawn(function()
	while true do
		task.wait(Config.BoardPushSeconds)
		for _, player in Players:GetPlayers() do
			task.spawn(tally.push, tally, player.UserId)
		end
	end
end)

-- Releases every session (each after the call still running for it) and waits for loads and
-- releases still running, within the timeout.
game:BindToClose(function()
	sessions:close()
end)
