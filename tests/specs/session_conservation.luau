--!strict
-- The session layer through the real server entry script: the real Sessions, Store, Lease and
-- Tally run over FakeGame, and every case ends the same way. A fresh server starts over the
-- stored records long after every lease has run out, each player joins, and what the players hold
-- is counted from what is stored, not from what the first server remembers. This is the gap the
-- pure-module specs can't see: a score that is kept in memory and never reaches the record, a
-- release that doesn't save, a second server that writes over the first.
local Config = require("../../src/shared/Config")
local Conservation = require("../fakes/Conservation")
local Deep = require("../fakes/Deep")
local FakeGame = require("../fakes/FakeGame")
local Faults = require("../fakes/Faults")
local Season = require("../../src/server/Season")

local USERS = { 1, 2 }
local START = 1000
local RESTART_AT = 50000 -- after every lease (180 s) has run out
-- A streak claim is refused on UTC day 0 (the first 86400 seconds), so the claim cases start on day 1
-- and restart on day 11.
local CLAIM_START = 100000
local CLAIM_RESTART = 1000000

-- Season 1 is [1000, 1100): short enough that a restart lands in a much later season.
local CONFIG: any = Deep.copy(Config)
CONFIG.Epoch = START
CONFIG.SeasonLengthSeconds = 100

local function started(options: any?): any
	local opts: any = table.clone(options or {})
	opts.config = opts.config or CONFIG
	opts.start = opts.start or START
	local world = FakeGame.new(opts)
	world:start()
	assert(world.started == true, world.startError)
	return world
end

local function stored(world: any, userId: number): any
	local record = world.records["Player_" .. userId]
	return if record ~= nil then record.data else nil
end

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function warned(world: any, text: string): boolean
	for _, line in world.warnings do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

-- The score a stored profile holds for season 1, or 0.
local function season1(world: any, userId: number): number
	local data = stored(world, userId)
	if data == nil or data.seasons["1"] == nil then
		return 0
	end
	return data.seasons["1"].score
end

-- The same config in best mode: the season keeps the highest single score, while lifetime still
-- counts every point recorded.
local BEST: any = Deep.copy(CONFIG)
BEST.ScoreMode = "best"

-- The stored records as Conservation reads them: a player's data under profile/<id>, season keys
-- as they are.
local function audited(records: any): any
	local out: any = {}
	for key, record in records do
		local id = string.match(key, "^Player_(%d+)$")
		if id ~= nil then
			out["profile/" .. id] = record.data
		else
			out[key] = record
		end
	end
	return out
end

-- Restarts a server over the stored records, has every player join (which settles what they are
-- owed) and leave and release, and counts from what is stored: no error was thrown, each player's
-- season 1 score is what `expected` says (when it is given), every point in the profile's lifetime
-- total is in some season (every point in these cases came through record, so the two agree), and
-- Conservation holds: every Coin is the start plus the season rewards, each paid once from a closed
-- season. In best mode the seasons hold only the highest score, so the caller gives `recorded`:
-- every point it recorded for each player, which lifetime must equal. Returns the restarted server.
local function settledAndCounted(
	world: any,
	expected: { [number]: number }?,
	recorded: { [number]: number }?,
	config: any?,
	restartAt: number?
): any
	local used: any = config or CONFIG
	local after = started({
		records = world.records,
		start = restartAt or RESTART_AT,
		server = "after-",
		config = config,
	})
	after.ordered = world.ordered -- the boards are shared by every server, as the real ones are
	for _, userId in USERS do
		after:join(userId)
	end
	after.sched:advance(Config.SettleSeconds * 3)
	for _, userId in USERS do
		after:leave(userId)
	end
	after.sched:advance(5)
	assert(#after.errors == 0, after.errors[1])
	local startCoins: { [number]: number } = {}
	for _, userId in USERS do
		startCoins[userId] = Config.StartingCoins
		local data = stored(after, userId)
		assert(data ~= nil, `player {userId} has no stored profile after the restart`)
		if expected ~= nil then
			local want = expected[userId] or 0
			assert(
				season1(after, userId) == want,
				`player {userId}: {season1(after, userId)} stored, expected {want}`
			)
		end
		local total = 0
		if recorded ~= nil then
			total = recorded[userId] or 0
		else
			for _, entry in data.seasons do
				total += entry.score
			end
		end
		assert((data.lifetime.points or 0) == total, `player {userId}: lifetime does not match the seasons`)
		assert(after.records["Player_" .. userId].lease == nil, "released")
	end
	local currentId = Season.idAt(used.Epoch, used.SeasonLengthSeconds, after.clock:now()) :: number
	local ok, reason = Conservation.check(
		audited(after.records),
		startCoins,
		{ currentId = currentId, mode = if used.ScoreMode == "best" then "best" else "sum" }
	)
	assert(ok, reason)
	return after
end

-- The next n store calls run `hook` (each call takes one), so a hang can be aimed at one key.
local function hookEach(world: any, n: number, hook: (key: string) -> ())
	for _ = 1, n do
		world.ds:hookNext(hook)
	end
end

-- Runs the next store read (once) as a wait of `seconds`, so a read can be parked mid-call. These
-- cases aim it at a settle's season read: a joining player's settle starts before their first Sync,
-- so it is the first to read (the Sync's board read is an ordered-store read, and comes after).
local function parkNextRead(world: any, seconds: number)
	local armed = true
	world.faults.onRead = function()
		if armed then
			armed = false
			world.sched:wait(seconds)
		end
	end
end

-- Joins, scores, lets the board timer push, leaves and lets the release land.
local function scoredAndLeft(world: any, userId: number, points: number)
	world:join(userId)
	world.sched:advance(1)
	assert(world:record(userId, points))
	world.sched:advance(Config.BoardPushSeconds + 1)
	world:leave(userId)
	world.sched:advance(5)
end

-- A server that starts over the same records and boards at `at` (season 11 at 2000), as the one
-- that pays the seasons the first server saw.
local function payingWorld(world: any, at: number?): any
	local paying = started({ records = world.records, start = at or 2000, server = "pay-" })
	paying.ordered = world.ordered
	return paying
end

local function coinsOf(world: any, userId: number): number
	return stored(world, userId).coins
end

local PAID_TEXT =
	"Season 1 is over. You scored 60 points, reached Silver and placed 1st on the podium. 450 Coins paid."

-- The paying server with player 1 joined while their settle is parked on its season read for
-- `seconds`. Returns the first server and the paying one.
local function parkedSettle(seconds: number): (any, any)
	local first = started()
	scoredAndLeft(first, 1, 60)
	local paying = payingWorld(first)
	parkNextRead(paying, seconds)
	paying:join(1)
	paying.sched:advance(1)
	return first, paying
end

return {
	{
		name = "a new player joins, is saved with the starting profile, and is synced into season 1",
		run = function()
			local world = started()
			world:join(1)
			world.sched:advance(1)
			local sync = world:lastSync(1)
			assert(sync ~= nil, "synced")
			assert(sync.season.id == 1 and sync.score == 0, `season {sync.season.id}, score {sync.score}`)
			local data = stored(world, 1)
			assert(data ~= nil, "saved at the join")
			assert(data.coins == Config.StartingCoins, tostring(data.coins))
			assert(count(data.seasons) == 0, "an empty seasons table")
			assert(Deep.equal(data.streak, { day = 0, count = 0, earned = 0 }), "the default streak")
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(1)
			settledAndCounted(world, {})
		end,
	},
	{
		name = "a score is in memory until the autosave, which stores it with the lifetime total",
		run = function()
			local world = started()
			world:join(1)
			world.sched:advance(1)
			local ok, why = world:record(1, 30)
			assert(ok and why == nil, tostring(why))
			world.sched:advance(10)
			assert(season1(world, 1) == 0 and stored(world, 1).lifetime.points == nil, "not stored yet")
			world.sched:advance(Config.AutosaveSeconds + 1)
			local data = stored(world, 1)
			assert(data.seasons["1"].score == 30, "the autosave wrote the season score")
			assert(data.lifetime.points == 30, "and the lifetime total")
			assert(world.records.Player_1.lease ~= nil, "still in play")
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(1)
			settledAndCounted(world, { [1] = 30 })
		end,
	},
	{
		name = "a player who scores and leaves has the score stored by the release",
		run = function()
			local world = started()
			world:join(1)
			world:join(2)
			world.sched:advance(1)
			assert(world:record(1, 40))
			assert(world:record(1, 2))
			assert(world:record(2, 9))
			world:leave(1)
			world.sched:advance(2)
			assert(world.records.Player_1.lease == nil, "released")
			assert(season1(world, 1) == 42, "the release stored it, there was no autosave")
			assert(stored(world, 1).lifetime.points == 42)
			assert(season1(world, 2) == 0, "the player still here has not been stored")
			world:leave(2)
			world.sched:advance(2)
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world, { [1] = 42, [2] = 9 })
		end,
	},
	{
		name = "a score from a player with no loaded session is refused as no_profile and counts for nothing",
		run = function()
			local world = started()
			-- The first store call (this player's load) hangs, so they are in the server without a session.
			world.ds:hookNext(function()
				world.sched:wait(20)
			end)
			world:join(1)
			world.sched:advance(1)
			local ok, why = world:record(1, 10)
			assert(not ok and why == "no_profile", tostring(why))
			assert(#world.errors == 0, world.errors[1])
			world.sched:advance(25)
			assert(world:record(1, 10), "once the session is live the same call is accepted")
			world:leave(1)
			world.sched:advance(2)
			settledAndCounted(world, { [1] = 10 })
		end,
	},
	{
		name = "shutdown releases every session and stores their scores",
		run = function()
			local world = started()
			world:join(1)
			world:join(2)
			world.sched:advance(1)
			assert(world:record(1, 11))
			assert(world:record(2, 22))
			assert(world.onClose ~= nil, "BindToClose was used")
			local closed = false
			world.sched:spawn(function()
				world.onClose()
				closed = true
			end)
			world.sched:advance(Config.CloseTimeoutSeconds)
			assert(closed, "BindToClose returned")
			assert(
				world.records.Player_1.lease == nil and world.records.Player_2.lease == nil,
				"both released"
			)
			assert(season1(world, 1) == 11 and season1(world, 2) == 22, "both scores stored")
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world, { [1] = 11, [2] = 22 })
		end,
	},
	{
		name = "a hung save does not stop shutdown returning, and the other player's record is stored",
		run = function()
			local world = started()
			world:join(1)
			world:join(2)
			world.sched:advance(1)
			assert(world:record(1, 11))
			assert(world:record(2, 22))
			hookEach(world, 20, function(key: string)
				if key == "Player_1" then
					world.sched:wait(math.huge)
				end
			end)
			local closed = false
			world.sched:spawn(function()
				world.onClose()
				closed = true
			end)
			world.sched:advance(Config.CloseTimeoutSeconds + 5)
			assert(closed, "onClose returned within the timeout")
			assert(season1(world, 2) == 22, "the other player's score was stored")
			assert(world.records.Player_2.lease == nil, "and released")
			assert(season1(world, 1) == 0, "the hung save never landed")
			-- The server is gone. A restart reads what was stored: player 2's score is there, and
			-- player 1's record is still readable once its lease has run out.
			settledAndCounted(world, { [2] = 22 })
		end,
	},
	{
		name = "a score reaches the ordered board on the timer, and with a rank lag only shows in sorted reads later",
		run = function()
			local world = started()
			world:join(1)
			world.sched:advance(1)
			assert(world:record(1, 30))
			assert(world.ordered["tally-1"] == nil or world.ordered["tally-1"].current["1"] == nil, "not yet")
			world.sched:advance(Config.BoardPushSeconds + 1)
			local board = world.orderedStore("tally-1")
			assert(board.current["1"] == 30, "the timer pushed the season score")
			assert(#world.errors == 0, world.errors[1])

			local lagged = started({ rankLag = 30 })
			lagged:join(1)
			lagged.sched:advance(1)
			assert(lagged:record(1, 30))
			lagged.sched:advance(Config.BoardPushSeconds + 1)
			local raw = lagged.orderedStore("tally-1")
			local handle = raw:handle(Faults.new())
			assert(handle:GetAsync("1") == 30, "GetAsync sees the write at once")
			assert(#handle:GetSortedAsync(false, 10):GetCurrentPage() == 0, "a sorted read does not yet")
			lagged.sched:advance(30)
			local page = handle:GetSortedAsync(false, 10):GetCurrentPage()
			assert(#page == 1 and page[1].key == "1" and page[1].value == 30, "after the lag it does")
			assert(#lagged.errors == 0, lagged.errors[1])
		end,
	},
	{
		name = "a player who scores and leaves before the timer has the score on the board at once",
		run = function()
			local world = started()
			world:join(1)
			world.sched:advance(1)
			assert(world:record(1, 17))
			world:leave(1)
			world.sched:advance(2)
			assert(world.orderedStore("tally-1").current["1"] == 17, "pushed on the way out")
			assert(season1(world, 1) == 17, "and stored")
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world, { [1] = 17 })
		end,
	},
	{
		name = "best mode keeps the highest single score in the season and every point in the lifetime total",
		run = function()
			local world = started({ config = BEST })
			world:join(1)
			world.sched:advance(1)
			for _, points in { 10, 30, 20 } do
				assert(world:record(1, points))
			end
			world:leave(1)
			world.sched:advance(2)
			local data = stored(world, 1)
			assert(data.seasons["1"].score == 30, `season score {data.seasons["1"].score}, the highest`)
			assert(data.lifetime.points == 60, `lifetime {data.lifetime.points}, every submission`)
			assert(#world.errors == 0, world.errors[1])
			settledAndCounted(world, { [1] = 30 }, { [1] = 60 }, BEST)
		end,
	},
	{
		-- A record saved by a newer version of the game opens read-only: shown, never changed. Scoring
		-- goes through writableSession, so it is refused; reading through `get` would take the score.
		name = "a read-only session is refused a score and its stored record is unchanged after a restart",
		run = function()
			local world = started()
			local newer: any = {
				schema = Config.SchemaVersion + 1,
				savedAt = 0,
				data = {
					coins = 5,
					lifetime = { points = 7 },
					seasons = { ["1"] = { score = 7, rewarded = false } },
					streak = { day = 0, count = 0, earned = 0 },
					notices = {},
				},
			}
			world.records.Player_1 = Deep.copy(newer)
			world:join(1)
			world.sched:advance(1)
			assert(world:lastSync(1) ~= nil, "the read-only session is still shown")
			local ok, why = world:record(1, 10)
			assert(not ok and why == "no_profile", tostring(why))
			world.sched:advance(Config.AutosaveSeconds + 1)
			world:leave(1)
			world.sched:advance(2)
			local record = world.records.Player_1
			assert(record.schema == newer.schema, "still the newer schema")
			assert(Deep.equal(record.data, newer.data), "the data is exactly as it was")
			assert(#world.errors == 0, world.errors[1])
			local after = started({ records = world.records, start = RESTART_AT, server = "after-" })
			assert(Deep.equal(after.records.Player_1.data, newer.data), "and after a restart")
		end,
	},
	{
		name = "a second server that takes over an expired session never has both write: the first is kicked",
		run = function()
			local first = started({ server = "a-" })
			first:join(1)
			first.sched:advance(1)
			assert(first:record(1, 5), "scored in season 1 on the first server")
			-- The first server stands still while a second starts after its lease has run out.
			local second = started({ records = first.records, start = START + 300, server = "b-" })
			second:join(1)
			second.sched:advance(1)
			assert(second:record(1, 50), "scored in season 4 on the second")
			-- The first server's autosave finds the record held by someone else.
			first.sched:advance(Config.AutosaveSeconds + 1)
			local player = first.players[1]
			assert(player.kicked ~= nil, "the first server's player was kicked")
			assert(season1(first, 1) == 0, "the first server's score was never written")
			second:leave(1)
			second.sched:advance(2)
			local data = stored(second, 1)
			assert(
				data.seasons["4"] ~= nil and data.seasons["4"].score == 50,
				"the second server's score is stored"
			)
			assert(data.seasons["1"] == nil, "and the first server's is not")
			assert(data.lifetime.points == 50, "the lifetime total counts only what was written")
			assert(#second.errors == 0, second.errors[1])
			assert(warned(first, "lost") or player.kicked ~= nil)
			settledAndCounted(first, {})
		end,
	},
	{
		name = "payout 1: a season is paid on the player's next join, once, with a notice and a closed season key",
		run = function()
			local first = started()
			scoredAndLeft(first, 1, 60)
			local paying = payingWorld(first)
			paying:join(1)
			paying.sched:advance(5)
			local data = stored(paying, 1)
			assert(data.coins == Config.StartingCoins + 450, `coins {data.coins}`)
			assert(
				Deep.equal(data.seasons["1"], { score = 60, rewarded = true, tier = "Silver", reward = 450 }),
				"the season entry"
			)
			assert(#data.notices == 1 and data.notices[1].text == PAID_TEXT, data.notices[1].text)
			local key = paying.records["season/1"]
			assert(key.state == "closed" and key.closedBy == "pay-", "closed by the paying server")
			assert(Deep.equal(key.podium, { { userId = 1, score = 60 } }), "the stored podium")
			local carried = 0
			for _, sent in paying.synced do
				for _, notice in sent.payload.notices do
					if notice.text == PAID_TEXT then
						carried += 1
					end
				end
			end
			assert(carried == 1, `the notice reached the player in {carried} Syncs`)
			assert(paying:lastSync(1).coins == Config.StartingCoins + 450)
			assert(#paying.errors == 0, paying.errors[1])
			paying:leave(1)
			paying.sched:advance(5)
			settledAndCounted(paying)
		end,
	},
	{
		name = "payout 2: joining again pays nothing more",
		run = function()
			local first = started()
			scoredAndLeft(first, 1, 60)
			local paying = payingWorld(first)
			paying:join(1)
			paying.sched:advance(5)
			for _ = 1, 2 do
				paying:leave(1)
				paying.sched:advance(5)
				paying:join(1)
				paying.sched:advance(5)
			end
			paying.sched:advance(Config.SettleSeconds * 2)
			local data = stored(paying, 1)
			assert(data.coins == Config.StartingCoins + 450, `coins {data.coins}`)
			assert(#data.notices == 1, `{#data.notices} notices`)
			paying:leave(1)
			paying.sched:advance(5)
			settledAndCounted(paying)
		end,
	},
	{
		name = "payout 3: a player is paid on whichever server they next join, from one close, with agreeing podiums",
		run = function()
			local a = started()
			scoredAndLeft(a, 1, 60)
			scoredAndLeft(a, 2, 40)
			a.clock:advance(1000)
			local b = started({ records = a.records, clock = a.clock, server = "b-" })
			local c = started({ records = a.records, clock = a.clock, server = "c-" })
			b.ordered = a.ordered
			c.ordered = a.ordered
			b:join(1)
			c:join(2)
			FakeGame.step({ b, c }, 5)
			assert(coinsOf(b, 1) == Config.StartingCoins + 450, `player 1 {coinsOf(b, 1)}`)
			assert(coinsOf(b, 2) == Config.StartingCoins + 250, `player 2 {coinsOf(b, 2)}`)
			local key = a.records["season/1"]
			assert(key.state == "closed" and key.closedBy == "b-", "one close, by the first server")
			assert(
				Deep.equal(key.podium, { { userId = 1, score = 60 }, { userId = 2, score = 40 } }),
				"both were paid from this one podium"
			)
			assert(#stored(b, 1).notices == 1 and #stored(b, 2).notices == 1)
			assert(#b.errors == 0 and #c.errors == 0, b.errors[1] or c.errors[1])
			b:leave(1)
			c:leave(2)
			FakeGame.step({ b, c }, 5)
			settledAndCounted(b)
		end,
	},
	{
		-- The mutant save_not_bound_to_profile: the old session's settle must not be allowed to save
		-- the new session, and so must not look paid.
		name = "payout 4: a player who leaves and rejoins while their settle is parked is paid once, by the new session",
		run = function()
			local _, paying = parkedSettle(50)
			paying:leave(1)
			paying.sched:advance(Config.CloseTimeoutSeconds + 3) -- the release gives up waiting and lands
			assert(paying.records.Player_1.lease == nil, "released")
			paying:join(1)
			paying.sched:advance(1)
			paying.sched:advance(25) -- the parked settle resumes at 2050
			assert(warned(paying, "payout save failed for 1"), "the old settle's save was refused")
			local data = stored(paying, 1)
			assert(data.coins == Config.StartingCoins, "not paid by the old settle")
			assert(data.seasons["1"].rewarded == false)
			paying.sched:advance(Config.SettleSeconds + 1)
			data = stored(paying, 1)
			assert(data.coins == Config.StartingCoins + 450, `coins {data.coins}`)
			assert(#data.notices == 1, `{#data.notices} notices`)
			assert(#paying.errors == 0, paying.errors[1])
			paying:leave(1)
			paying.sched:advance(5)
			settledAndCounted(paying)
		end,
	},
	{
		-- A stale save must not touch the live session's stored record, and what the new session
		-- scores must reach the store and survive a crash.
		name = "payout 4b: a stale settle's save leaves the stored record alone, and the new session's points survive a crash",
		run = function()
			local _, paying = parkedSettle(50)
			paying:leave(1)
			paying.sched:advance(Config.CloseTimeoutSeconds + 3)
			paying:join(1)
			paying.sched:advance(1)
			assert(paying:record(1, 7), "scored on the new session, in season 11")
			local before = Deep.copy(paying.records.Player_1)
			paying.sched:advance(25) -- the parked settle resumes at 2050, before the next autosave
			assert(warned(paying, "payout save failed for 1"), "the stale save was refused")
			assert(
				Deep.equal(paying.records.Player_1, before),
				"the stale settle wrote nothing to the record"
			)
			assert(season1(paying, 1) == 60 and paying.records.Player_1.data.seasons["1"].rewarded == false)
			paying.sched:advance(Config.AutosaveSeconds + 1)
			-- The server crashes here: nothing more runs on it, and nothing releases.
			local data = stored(paying, 1)
			assert(
				data.seasons["11"] ~= nil and data.seasons["11"].score == 7,
				"the 7 points reached the store"
			)
			assert(data.lifetime.points == 67, `lifetime {data.lifetime.points}`)
			assert(data.coins == Config.StartingCoins + 450 and data.seasons["1"].rewarded == true)
			local after = settledAndCounted(paying)
			data = stored(after, 1)
			assert(data.seasons["11"].score == 7 and data.lifetime.points == 67, "after the restart")
			-- Season 1 paid once (450), and the 7 points in season 11 are paid on the restart (no tier, and
			-- first place on that board: 300).
			assert(data.seasons["1"].reward == 450 and data.seasons["11"].reward == 300)
			assert(data.coins == Config.StartingCoins + 750, `each season paid once: {data.coins}`)
			assert(#data.notices == 2)
		end,
	},
	{
		name = "payout 5: a lease stolen while the settle is parked rolls the payout back, kicks the player, and pays once later",
		run = function()
			local _, paying = parkedSettle(30)
			paying.records.Player_1.lease = { owner = "thief", expiresAt = 1e9 }
			paying.sched:advance(30) -- the parked settle resumes at 2030 and its save finds the lease gone
			assert(warned(paying, "payout save failed for 1"), "the payout save failed")
			assert(paying.players[1].kicked ~= nil, "the player was kicked")
			assert(paying.records.Player_1.lease.owner == "thief", "the thief's lease is untouched")
			local data = stored(paying, 1)
			assert(data.coins == Config.StartingCoins and data.seasons["1"].rewarded == false, "nothing paid")
			assert(#data.notices == 0)
			paying.records.Player_1.lease = nil
			local after = settledAndCounted(paying)
			data = stored(after, 1)
			assert(data.coins == Config.StartingCoins + 450 and #data.notices == 1, `coins {data.coins}`)
		end,
	},
	{
		name = "payout 6: a player who leaves while the settle is parked is not paid there, and is paid once on the next server",
		run = function()
			local _, paying = parkedSettle(60)
			paying:leave(1)
			paying.sched:advance(Config.CloseTimeoutSeconds + 3)
			assert(paying.records.Player_1.lease == nil, "released")
			assert(coinsOf(paying, 1) == Config.StartingCoins and not warned(paying, "payout save failed"))
			paying.sched:advance(40) -- the parked settle resumes at 2060
			assert(warned(paying, "payout save failed for 1"), "its save was refused: the session is gone")
			local data = stored(paying, 1)
			assert(data.coins == Config.StartingCoins and data.seasons["1"].rewarded == false, "nothing paid")
			assert(#paying.errors == 0, paying.errors[1])
			local after = settledAndCounted(paying)
			data = stored(after, 1)
			assert(data.coins == Config.StartingCoins + 450 and #data.notices == 1, `coins {data.coins}`)
		end,
	},
	{
		name = "payout 7: shutdown returns while a payout save hangs, and a restarted server pays at most once",
		run = function()
			local _, paying = parkedSettle(20)
			hookEach(paying, 20, function(key: string)
				if key == "Player_1" then
					paying.sched:wait(math.huge)
				end
			end)
			paying.sched:advance(25) -- the settle resumes, closes the season, and its save hangs
			assert(paying.records["season/1"].state == "closed", "the settle reached its save")
			assert(coinsOf(paying, 1) == Config.StartingCoins, "the save never landed")
			local closed = false
			paying.sched:spawn(function()
				paying.onClose()
				closed = true
			end)
			paying.sched:advance(Config.CloseTimeoutSeconds + 5)
			assert(closed, "onClose returned within the timeout")
			local after = settledAndCounted(paying)
			local data = stored(after, 1)
			assert(data.coins == Config.StartingCoins + 450 and #data.notices == 1, `coins {data.coins}`)
		end,
	},
	{
		name = "payout 8: a payout is one save of the profile, and the close is one write of the season key",
		run = function()
			local _, paying = parkedSettle(20)
			paying.ds.events = {}
			paying.sched:advance(25) -- the settle resumes: close, pay
			local profile, season = 0, 0
			for _, event in paying.ds.events do
				if event == "call Player_1" then
					profile += 1
				elseif event == "call season/1" then
					season += 1
				end
			end
			assert(profile == 1, `{profile} saves of the profile`)
			assert(season == 1, `{season} writes of season/1: the close (the first server opened it)`)
			assert(coinsOf(paying, 1) == Config.StartingCoins + 450)
			paying:leave(1)
			paying.sched:advance(5)
			settledAndCounted(paying)
		end,
	},
	{
		name = "payout 9: the podium bonus comes from the stored close, not the live board",
		run = function()
			local first = started()
			scoredAndLeft(first, 1, 60)
			scoredAndLeft(first, 2, 40)
			local paying = payingWorld(first)
			paying:join(1) -- this closes season 1 with podium 1 then 2
			paying.sched:advance(5)
			assert(
				Deep.equal(
					paying.records["season/1"].podium,
					{ { userId = 1, score = 60 }, { userId = 2, score = 40 } }
				)
			)
			paying.orderedStore("tally-1"):write("3", 5000) -- a new leader on the live board
			paying:join(2)
			paying.sched:advance(5)
			assert(coinsOf(paying, 2) == Config.StartingCoins + 250, `player 2 {coinsOf(paying, 2)}`)
			assert(string.find(stored(paying, 2).notices[1].text, "placed 2nd on the podium", 1, true))
			paying:leave(1)
			paying:leave(2)
			paying.sched:advance(5)
			settledAndCounted(paying)
		end,
	},
	{
		name = "streak 1: a claim_streak request pays 10 in one write, and the autosave shows the streak and the notice",
		run = function()
			local world = started({ start = CLAIM_START })
			world:join(1)
			world.sched:advance(2)
			assert(world:lastSync(1).streak.canClaim == true)
			local writes = world.faults.writes
			world:request(1, "claim_streak")
			assert(world.faults.writes - writes == 1, `{world.faults.writes - writes} writes for one claim`)
			local sync = world:lastSync(1)
			assert(Deep.equal(sync.result, { action = "claim_streak", ok = true, reward = 10 }))
			assert(sync.coins == Config.StartingCoins + 10 and sync.streak.canClaim == false)
			assert(#sync.notices == 1 and sync.notices[1].text == "Streak day 1: 10 Coins claimed.")
			world.sched:advance(Config.AutosaveSeconds + 1)
			local data = stored(world, 1)
			assert(
				data.streak.count == 1 and data.streak.earned == 10 and data.streak.day == 1,
				"streak stored"
			)
			assert(data.coins == Config.StartingCoins + 10 and #data.notices == 1)
			-- The same request the same day is refused and changes nothing.
			world.sched:advance(1)
			writes = world.faults.writes
			world:request(1, "claim_streak")
			assert(
				world:lastSync(1).result.reason == "already_claimed" and world:lastSync(1).result.ok == false
			)
			assert(world.faults.writes == writes, "a refused claim writes nothing")
			assert(world:lastSync(1).coins == Config.StartingCoins + 10)
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(5)
			settledAndCounted(world, nil, nil, nil, CLAIM_RESTART)
		end,
	},
	{
		name = "streak 2: a claim on the next UTC day, inside the lease, continues the streak",
		run = function()
			local world = started({ start = CLAIM_START })
			world:join(1)
			world.sched:advance(2)
			world:request(1, "claim_streak")
			assert(world:lastSync(1).result.reward == 10)
			world.sched:advance(86400) -- the autosave renews the lease every minute
			assert(world.records.Player_1.lease ~= nil and not world.players[1].kicked, "still the owner")
			world:request(1, "claim_streak")
			local sync = world:lastSync(1)
			assert(
				Deep.equal(sync.result, { action = "claim_streak", ok = true, reward = 15 }),
				tostring(sync.result.reason)
			)
			assert(sync.streak.count == 2 and sync.coins == Config.StartingCoins + 25)
			world.sched:advance(Config.AutosaveSeconds + 1)
			local data = stored(world, 1)
			assert(data.streak.count == 2 and data.streak.earned == 25 and data.streak.day == 2)
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world.sched:advance(5)
			settledAndCounted(world, nil, nil, nil, CLAIM_RESTART)
		end,
	},
	{
		name = "streak 3: a crash after a claim finds the Coins, the streak and the notice together or not at all",
		run = function()
			local world = started({ start = CLAIM_START })
			world:join(1)
			world.sched:advance(2)
			-- The claim's own write is write 1; a second write would be a second save for the same claim.
			world.faults:arm(2, "stop")
			world:request(1, "claim_streak")
			local data = stored(world, 1)
			assert(world.faults.dead == false, "a claim needs only one write")
			assert(data.coins == Config.StartingCoins + 10, `Coins {data.coins}`)
			assert(data.streak.count == 1 and data.streak.earned == 10, "the streak is in the same write")
			assert(#data.notices == 1, "so is the notice")
			-- A crash on the claim's own write leaves none of the three.
			local other = started({ start = CLAIM_START, server = "other-" })
			other:join(2)
			other.sched:advance(2)
			other.faults:arm(1, "stop")
			other:request(2, "claim_streak")
			local before = stored(other, 2)
			assert(before.coins == Config.StartingCoins and before.streak.count == 0 and #before.notices == 0)
			assert(other.faults.dead == true)
		end,
	},
	{
		name = "sync 1: a Sync carries the server clock, season, score, rank, board, streak and notices, and a player with no score has no rank",
		run = function()
			local world = started({ start = CLAIM_START })
			world:join(1)
			world:join(2)
			world.sched:advance(1)
			assert(world:record(1, 30))
			world.sched:advance(Config.BoardPushSeconds + 1)
			world:request(1, "board_page", 1)
			world:request(2, "board_page", 1)
			local mine = world:lastSync(1)
			assert(type(mine.coins) == "number" and mine.coins == Config.StartingCoins)
			assert(mine.serverNow == math.floor(world.clock:now()), `serverNow {mine.serverNow}`)
			assert(mine.season.id == 991 and mine.season.endsAt == 100100 and mine.season.state == "open")
			assert(mine.score == 30 and mine.rank == 1, `score {mine.score} rank {tostring(mine.rank)}`)
			assert(mine.board.page == 1 and #mine.board.entries == 1)
			assert(mine.board.entries[1].userId == 1 and mine.board.entries[1].score == 30)
			assert(Deep.equal(mine.streak, { count = 0, canClaim = true, broken = false, nextReward = 10 }))
			assert(type(mine.notices) == "table" and #mine.notices == 0)
			assert(mine.result == nil or mine.result.action == "board_page")
			local theirs = world:lastSync(2)
			assert(theirs.score == 0 and theirs.rank == nil, "no score, no rank")
			assert(theirs.board.entries[1].userId == 1, "the cached board is the same for both")
			world:request(1, "board_page", 4)
			assert(world:lastSync(1).board.page == 4, "the page asked for comes back")
			assert(#world.errors == 0, world.errors[1])
			world:leave(1)
			world:leave(2)
			world.sched:advance(5)
			settledAndCounted(world, nil, nil, nil, CLAIM_RESTART)
		end,
	},
	{
		name = "sync 2: a joining player's first Sync arrives before their settle completes",
		run = function()
			local _, paying = parkedSettle(50)
			local sync = paying:lastSync(1)
			assert(sync ~= nil, "synced while the settle is parked on its season read")
			assert(sync.coins == Config.StartingCoins, "the settle has not paid yet")
			assert(coinsOf(paying, 1) == Config.StartingCoins and not warned(paying, "payout save failed"))
			paying.sched:advance(60)
			assert(coinsOf(paying, 1) == Config.StartingCoins + 450, "then it pays")
			assert(paying:lastSync(1).coins == Config.StartingCoins + 450)
			assert(#paying.errors == 0, paying.errors[1])
			paying:leave(1)
			paying.sched:advance(5)
			settledAndCounted(paying)
		end,
	},
	{
		name = "streak 4: a read-only session's claim_streak and board_page requests are dropped, with no answer and no change",
		run = function()
			local world = started({ start = CLAIM_START })
			local newer: any = {
				schema = Config.SchemaVersion + 1,
				savedAt = 0,
				data = {
					coins = 5,
					lifetime = {},
					seasons = {},
					streak = { day = 0, count = 0, earned = 0 },
					notices = {},
				},
			}
			world.records.Player_1 = Deep.copy(newer)
			world:join(1)
			world.sched:advance(1)
			assert(world:lastSync(1) ~= nil, "the read-only session is shown")
			local syncs = #world.synced
			local writes = world.faults.writes
			world:request(1, "claim_streak")
			world.sched:advance(1)
			world:request(1, "board_page", 2)
			assert(#world.synced == syncs, "a call from a session that would not be saved gets no answer")
			assert(world.faults.writes == writes, "and writes nothing")
			assert(Deep.equal(world.records.Player_1.data, newer.data))
			assert(#world.errors == 0, world.errors[1])
		end,
	},
}
