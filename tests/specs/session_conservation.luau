--!strict
-- The session layer through the real server entry script: the real Sessions, Store, Lease and
-- Tally run over FakeGame, and every case ends the same way. A fresh server starts over the
-- stored records long after every lease has run out, each player joins, and what the players hold
-- is counted from what is stored, not from what the first server remembers. This is the gap the
-- pure-module specs can't see: a score that is kept in memory and never reaches the record, a
-- release that doesn't save, a second server that writes over the first.
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeGame = require("../fakes/FakeGame")
local Faults = require("../fakes/Faults")

local USERS = { 1, 2 }
local START = 1000
local RESTART_AT = 50000 -- after every lease (180 s) has run out

-- Season 1 is [1000, 1100): short enough that a restart lands in a much later season.
local CONFIG: any = Deep.copy(Config)
CONFIG.Epoch = START
CONFIG.SeasonLengthSeconds = 100

local function started(options: any?): any
	local opts: any = table.clone(options or {})
	opts.config = CONFIG
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

-- Restarts a server over the stored records, has every player join, leave and release, and counts
-- from what is stored: no error was thrown, each player's season 1 score is what `expected` says,
-- and every point in the profile's lifetime total is in some season (every point in these cases
-- came through record, so the two agree). Returns the restarted server.
local function settledAndCounted(world: any, expected: { [number]: number }): any
	local after = started({ records = world.records, start = RESTART_AT, server = "after-" })
	for _, userId in USERS do
		after:join(userId)
	end
	after.sched:advance(Config.SettleSeconds * 3)
	for _, userId in USERS do
		after:leave(userId)
	end
	after.sched:advance(5)
	assert(#after.errors == 0, after.errors[1])
	for _, userId in USERS do
		local data = stored(after, userId)
		assert(data ~= nil, `player {userId} has no stored profile after the restart`)
		local want = expected[userId] or 0
		assert(
			season1(after, userId) == want,
			`player {userId}: {season1(after, userId)} stored, expected {want}`
		)
		local total = 0
		for _, entry in data.seasons do
			total += entry.score
		end
		assert((data.lifetime.points or 0) == total, `player {userId}: lifetime does not match the seasons`)
		assert(after.records["Player_" .. userId].lease == nil, "released")
	end
	return after
end

-- The next n store calls run `hook` (each call takes one), so a hang can be aimed at one key.
local function hookEach(world: any, n: number, hook: (key: string) -> ())
	for _ = 1, n do
		world.ds:hookNext(hook)
	end
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
}
