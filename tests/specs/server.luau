--!strict
-- The server entry script itself, run under Lune over FakeGame: it starts, makes its remotes and
-- the TallyRecord function, refuses a bad config, and starts in Studio on an unpublished place with
-- in-memory stores for both the data and the board.
local Config = require("../../src/shared/Config")
local FakeGame = require("../fakes/FakeGame")

local function started(options: any?): any
	local world = FakeGame.new(options)
	world:start()
	assert(world.started == true, world.startError)
	return world
end

local function warned(world: any, text: string): boolean
	for _, line in world.warnings do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

return {
	{
		name = "the script starts and makes Request, Sync and TallyRecord, with no errors",
		run = function()
			local world = started()
			assert(world:remote("Request") ~= nil and world:remote("Request").ClassName == "RemoteEvent")
			assert(world:remote("Sync") ~= nil and world:remote("Sync").ClassName == "RemoteEvent")
			local record = world:remote("TallyRecord")
			assert(
				record ~= nil and record.ClassName == "BindableFunction",
				"TallyRecord is a BindableFunction"
			)
			assert(record.OnInvoke ~= nil, "and it is wired")
			assert(world.serverStorage.Children[1] == record, "it lives in ServerStorage")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a config that fails its checks warns and creates nothing",
		run = function()
			local bad = table.clone(Config)
			bad.PodiumSize = 0
			local world = FakeGame.new({ config = bad })
			world:start()
			assert(world.started == true, world.startError)
			assert(world:remote("Request") == nil and world:remote("Sync") == nil, "no remotes")
			assert(world:remote("TallyRecord") == nil, "no TallyRecord")
			assert(#world.serverStorage.Children == 0, "nothing in ServerStorage")
			assert(warned(world, "config problem"), "the problem is warned about")
			assert(warned(world, "PodiumSize"), "and named")
		end,
	},
	{
		name = "a module that fails to load surfaces as a start error",
		run = function()
			local world = FakeGame.new({ failRequire = "Tally" })
			world:start()
			assert(world.started == false, "did not start")
			assert(world.startError ~= nil and string.find(world.startError, "Tally failed to load", 1, true))
		end,
	},
	{
		name = "a shared folder that never arrives leaves the script waiting without an error",
		run = function()
			local world = FakeGame.new({ blockShared = true })
			world:start()
			assert(world.started == nil and world.startError == nil, "still waiting")
			assert(world:remote("Request") == nil)
		end,
	},
	{
		name = "a joining player is synced with the starting profile and the current season",
		run = function()
			local world = started({ start = Config.Epoch + 10 })
			world:join(1)
			local sync = world:lastSync(1)
			assert(sync ~= nil, "synced")
			assert(sync.coins == Config.StartingCoins and sync.score == 0)
			assert(sync.season.id == 1, tostring(sync.season and sync.season.id))
			assert(sync.season.endsAt == Config.Epoch + Config.SeasonLengthSeconds)
			assert(#sync.notices == 0)
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		-- The saleyards lesson: a Studio place that was never published can't reach DataStoreService,
		-- so the data AND the board must be in memory or the script stops at startup.
		name = "Studio on an unpublished place starts, a player scores and the in-memory board takes a push",
		run = function()
			local world = started({ studio = true, unpublished = true, start = Config.Epoch + 10 })
			assert(world.ds.calls == 0, "no real data store was touched")
			assert(world.ordered["tally-1"] == nil, "and no real ordered store was made")
			assert(warned(world, "Studio") == false, "it printed, it did not warn")
			assert(not warned(world, "real data stores"), "and it did not fall back: it never asked for them")
			world:join(1)
			world.sched:advance(1)
			assert(world:lastSync(1) ~= nil, "joined")
			local ok, why = world:record(1, 30)
			assert(ok and why == nil, tostring(why))
			world.sched:advance(Config.BoardPushSeconds + 1)
			assert(#world.memoryBoards == 1, "the script made one in-memory board")
			assert(world.memoryBoards[1]:GetAsync("1") == 30, "and it holds the pushed score")
			assert(#world.errors == 0, world.errors[1])
			assert(not warned(world, "failed"), world.warnings[1])
		end,
	},
	{
		name = "a Studio demo season is DemoSeasonSeconds long in the first Sync",
		run = function()
			local world = started({
				studio = true,
				attributes = { TallyDemoSeason = true },
				start = Config.Epoch + 500,
			})
			world:join(1)
			local season = world:lastSync(1).season
			local startsAt = Config.Epoch + (season.id - 1) * Config.DemoSeasonSeconds
			assert(
				season.endsAt - startsAt == Config.DemoSeasonSeconds,
				`season {season.id} ends {season.endsAt}`
			)
			assert(season.id == 500 // Config.DemoSeasonSeconds + 1, "the id follows the demo length")
			-- control: the same attribute outside Studio is ignored
			local live = started({ attributes = { TallyDemoSeason = true }, start = Config.Epoch + 500 })
			live:join(1)
			assert(live:lastSync(1).season.id == 1, "a live server keeps the real length")
		end,
	},
	{
		name = "Studio with TallyUseDataStore on an unpublished place warns once and falls back to in-memory stores",
		run = function()
			local world = started({
				studio = true,
				unpublished = true,
				attributes = { TallyUseDataStore = true },
				start = Config.Epoch + 10,
			})
			local warnings = 0
			for _, line in world.warnings do
				if string.find(line, "real data stores aren't available", 1, true) then
					warnings += 1
				end
			end
			assert(warnings == 1, `{warnings} warnings`)
			assert(warned(world, "nothing will be saved"), "in plain words")
			assert(world:remote("Request") ~= nil and world:remote("TallyRecord") ~= nil, "it started")
			assert(world.onClose ~= nil, "BindToClose is registered")
			world:join(1)
			world.sched:advance(1)
			assert(world:lastSync(1) ~= nil, "a player joins")
			assert(world:record(1, 30), "and scores")
			world.sched:advance(Config.BoardPushSeconds + 1)
			assert(world.ds.calls == 0 and world.ordered["tally-1"] == nil, "no real store was used")
			assert(world.memoryBoards[1]:GetAsync("1") == 30, "the in-memory board holds the score")
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "a live server whose real stores are not available stops rather than run unsaved",
		run = function()
			local world = FakeGame.new({ unpublished = true })
			world:start()
			assert(world.started == false and world.startError ~= nil)
			assert(string.find(world.startError, "You must publish this place", 1, true), world.startError)
		end,
	},
	{
		name = "demo seed: a Studio join closes the seeded prior season and the first Sync carries the reward notice",
		run = function()
			local world = started({
				studio = true,
				unpublished = true,
				attributes = { TallyDemoSeed = true, TallyDemoSeason = true },
				start = Config.Epoch + 5 * Config.DemoSeasonSeconds + 10,
			})
			world:join(1)
			world.sched:advance(Config.SettleSeconds + 1)
			local sync = world:lastSync(1)
			assert(sync ~= nil and sync.season.id == 6, tostring(sync and sync.season.id))
			local found = false
			for _, entry in world:allSynced(1) do
				for _, notice in entry.notices do
					if string.find(notice.text, "Season 5 is over. You scored 85 points, ", 1, true) then
						found = true
					end
				end
			end
			assert(found, "a Sync carried the season 5 notice")
			assert(sync.coins > Config.StartingCoins, "and the Coins were paid")
			assert(
				world.memoryBoards[1] ~= nil and world.memoryBoards[1]:GetAsync("101") ~= nil,
				"the board is seeded"
			)
			assert(#world.errors == 0, world.errors[1])
			assert(not warned(world, "demo seed failed"), "no seeding error")
		end,
	},
	{
		name = "demo seed: without the TallyDemoSeed attribute nothing is seeded",
		run = function()
			local world = started({
				studio = true,
				unpublished = true,
				attributes = { TallyDemoSeason = true },
				start = Config.Epoch + 5 * Config.DemoSeasonSeconds + 10,
			})
			world:join(1)
			world.sched:advance(Config.SettleSeconds + 1)
			assert(
				#world.memoryBoards == 0 or world.memoryBoards[1]:GetAsync("101") == nil,
				"the board is not seeded"
			)
			assert(world:lastSync(1).coins == Config.StartingCoins, "nothing was paid")
			for _, entry in world:allSynced(1) do
				assert(#entry.notices == 0, "no reward notice")
			end
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "demo seed: outside Studio nothing is seeded, even with the attribute",
		run = function()
			local world = started({
				attributes = { TallyDemoSeed = true, TallyDemoSeason = true },
				start = Config.Epoch + 6 * Config.SeasonLengthSeconds + 10,
			})
			world:join(1)
			world.sched:advance(Config.SettleSeconds + 1)
			assert(
				#world.memoryBoards == 0 or world.memoryBoards[1]:GetAsync("101") == nil,
				"the board is not seeded"
			)
			assert(world:lastSync(1).coins == Config.StartingCoins, "nothing was paid")
			for _, entry in world:allSynced(1) do
				assert(#entry.notices == 0, "no reward notice")
			end
			assert(#world.errors == 0, world.errors[1])
		end,
	},
	{
		name = "demo seed: with TallyUseDataStore on a published place nothing is seeded",
		run = function()
			local world = started({
				studio = true,
				attributes = { TallyDemoSeed = true, TallyDemoSeason = true, TallyUseDataStore = true },
				start = Config.Epoch + 5 * Config.DemoSeasonSeconds + 10,
			})
			world:join(1)
			world.sched:advance(Config.SettleSeconds + 1)
			assert(
				#world.memoryBoards == 0 or world.memoryBoards[1]:GetAsync("101") == nil,
				"the board is not seeded"
			)
			assert(world:lastSync(1).coins == Config.StartingCoins, "nothing was paid")
			for _, entry in world:allSynced(1) do
				assert(#entry.notices == 0, "no reward notice")
			end
			assert(#world.errors == 0, world.errors[1])
		end,
	},
}
