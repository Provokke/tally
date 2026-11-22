--!strict
-- What a client can make the server spend, through the real entry script: DataStore writes, season
-- reads, ordered reads and Syncs. The timers that would also touch the stores (autosave, the season
-- tick) are set far off, so every event counted here is one a client's calls could have caused.
local Config = require("../../src/shared/Config")
local Deep = require("../fakes/Deep")
local FakeGame = require("../fakes/FakeGame")
local Season = require("../../src/server/Season")

-- UTC day 20000 plus a second a bit: a streak claim is refused on day 0, which is where 1000 falls.
local START = 20000 * 86400 + 1000

local CONFIG: any = Deep.copy(Config)
CONFIG.Epoch = START
CONFIG.SeasonLengthSeconds = 100
CONFIG.AutosaveSeconds = 100000
CONFIG.LeaseSeconds = 200000
CONFIG.SeasonTickSeconds = 100000

local function started(): any
	local world = FakeGame.new({ config = CONFIG, start = START })
	world:start()
	assert(world.started == true, world.startError)
	return world
end

-- Every player joins and the world settles for two seconds, then events are recorded.
local function joined(users: { number }): any
	local world = started()
	for _, userId in users do
		world:join(userId)
	end
	world.sched:advance(2)
	world.ds.events = {}
	return world
end

local function eventsWith(world: any, prefix: string): number
	local n = 0
	for _, event in world.ds.events do
		if string.sub(event, 1, #prefix) == prefix then
			n += 1
		end
	end
	return n
end

local function syncsFor(world: any, userId: number): number
	local n = 0
	for _, sent in world.synced do
		if sent.userId == userId then
			n += 1
		end
	end
	return n
end

return {
	{
		name = "ten players asking for board pages cost one ordered read per refresh window",
		run = function()
			local users = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
			local world = joined(users)
			local board = world.orderedStore("tally-1")
			assert(board.sortedReads == 1, `{board.sortedReads} reads for the first Syncs`)
			for _, userId in users do
				for i = 1, 20 do
					world:request(userId, "board_page", 1 + i % 5)
				end
			end
			assert(board.sortedReads == 1, `{board.sortedReads} reads for 200 board_page calls`)
			world.sched:advance(8)
			world:request(1, "board_page", 2)
			assert(board.sortedReads == 1, "still inside the window")
			world.sched:advance(Config.BoardRefreshSeconds + 1)
			world:request(1, "board_page", 2)
			assert(board.sortedReads == 2, `{board.sortedReads} reads after the window`)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a spam of claims and board pages makes no settle or season read, at most one profile write, and Syncs bounded by the rate limit",
		run = function()
			local world = joined({ 1 })
			world.synced = {}
			local limits = Config.Limits
			for i = 1, 100 do
				world:request(
					1,
					if i % 2 == 0 then "claim_streak" else "board_page",
					if i % 2 == 0 then nil else 2
				)
			end
			assert(eventsWith(world, "get season/") == 0, "no season read")
			assert(eventsWith(world, "call season/") == 0, "no season write")
			assert(eventsWith(world, "get Player_") == 0, "no profile read")
			assert(
				eventsWith(world, "call Player_1") <= 1,
				`{eventsWith(world, "call Player_1")} profile writes`
			)
			local syncs = syncsFor(world, 1)
			assert(syncs <= limits.BurstPerPlayer + limits.RefillPerSecond, `{syncs} Syncs for 100 calls`)
			assert(syncs >= 1)
			-- And over a longer window: 2 calls a second for a minute.
			world.synced = {}
			for i = 1, 120 do
				world:request(
					1,
					if i % 2 == 0 then "claim_streak" else "board_page",
					if i % 2 == 0 then nil else 2
				)
				world.sched:advance(0.5)
			end
			assert(eventsWith(world, "get season/") == 0 and eventsWith(world, "call season/") == 0)
			assert(eventsWith(world, "get Player_") == 0)
			assert(eventsWith(world, "call Player_1") <= 1, "the one legitimate claim is the only write")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a claim loop at 2 calls a second for a minute makes at most (burst + per-minute) / cost saves, and the allowance comes back",
		run = function()
			local world = joined({ 1 })
			local limits = Config.Limits
			local before = world.faults.writes
			world.ds:failNext(100000, "store is down") -- every save fails, so every allowed claim is a write
			local slow = 0
			for _ = 1, 120 do
				world:request(1, "claim_streak")
				if world:lastSync(1).result ~= nil and world:lastSync(1).result.reason == "slow_down" then
					slow += 1
				end
				world.sched:advance(0.5)
			end
			local writes = eventsWith(world, "call Player_1")
			local allowed = (limits.StoreBurstPerPlayer + limits.StoreOpsPerMinute)
				// limits.StoreCost.claim_streak
			assert(writes <= allowed, `{writes} profile writes in a minute, at most {allowed}`)
			assert(writes >= 1 and slow > 0, `{writes} writes, {slow} told to slow down`)
			assert(world.faults.writes - before == writes)
			local coins = world:lastSync(1).coins
			assert(coins == Config.StartingCoins, "no failed claim paid anything")
			-- The store comes back and the allowance refills: one claim now pays once.
			world.ds.failures = 0
			world.sched:advance(60)
			world:request(1, "claim_streak")
			local result = world:lastSync(1).result
			assert(result.ok == true and result.reward == 10, tostring(result.reason))
			assert(world:lastSync(1).coins == Config.StartingCoins + 10)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a settle runs once per poll whatever a client sends, as one season read and no write",
		run = function()
			local world = started()
			world:join(1)
			world.sched:advance(1)
			assert(world:record(1, 20))
			world.sched:advance(105) -- season 2 now; season 1 is old and unpaid
			-- Season 1's key is open with a far-off end, so a settle waits on it.
			world.records["season/1"] = Season.open(nil, 1, START, START + 1000000000)
			world.ds.events = {}
			-- Polls fall 120, 180 and 240 seconds after the start (every SettleSeconds).
			local function spam()
				for i = 1, 40 do
					world:request(
						1,
						if i % 2 == 0 then "claim_streak" else "board_page",
						if i % 2 == 0 then nil else 3
					)
				end
			end
			spam()
			assert(eventsWith(world, "get season/") == 0, "a client's calls read no season")
			world.sched:advance(20) -- 125 seconds in: one poll
			assert(
				eventsWith(world, "get season/1") == 1,
				`{eventsWith(world, "get season/1")} reads, one poll`
			)
			spam()
			world.sched:advance(60) -- 185: two polls
			assert(
				eventsWith(world, "get season/1") == 2,
				`{eventsWith(world, "get season/1")} reads, two polls`
			)
			spam()
			world.sched:advance(60) -- 245: three polls
			assert(
				eventsWith(world, "get season/1") == 3,
				`{eventsWith(world, "get season/1")} reads, three polls`
			)
			world.sched:advance(50) -- 295: no poll
			assert(eventsWith(world, "get season/") == 3)
			assert(eventsWith(world, "call season/") == 0, "a settle that waits writes no season key")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "no request changes a season score: record, score and the like are dropped, and the score stays what the game gave",
		run = function()
			local world = joined({ 1 })
			assert(world:record(1, 5))
			world.sched:advance(1)
			for _, name in { "record", "score", "add_points", "points", "setScore" } do
				world:request(1, name, 1000)
				world:request(1, name, 1000, 1000)
				world.sched:advance(1)
			end
			world:request(1, "claim_streak")
			world:request(1, "board_page", 2)
			assert(world:lastSync(1).score == 5, `score {world:lastSync(1).score}`)
			world.sched:advance(3)
			world:request(1, "board_page", 3)
			assert(world:lastSync(1).score == 5)
			assert(world:lastSync(1).coins == Config.StartingCoins + 10, "only the streak paid Coins")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
}
