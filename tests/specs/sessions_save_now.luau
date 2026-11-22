--!strict
-- Sessions:saveNow: a save the caller waits for. True only when the write landed, and it never
-- runs at the same time as an autosave of the same session.
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local FakeScheduler = require("../fakes/FakeScheduler")
local Config = require("../../src/shared/Config")
local Sessions = require("../../src/server/Sessions")
local StoreServer = require("../fakes/StoreServer")

local function world(): any
	local w: any = { records = {}, kicks = {}, players = {}, logs = {} }
	w.clock = FakeClock.new(0)
	w.sched = FakeScheduler.new(w.clock)
	-- The saved shape, kept inline so these specs only need the data layer.
	local profile = {
		defaultData = function(): any
			return {
				coins = Config.StartingCoins,
				lifetime = {},
				seasons = {},
				streak = { day = 0, count = 0, earned = 0 },
				notices = {},
			}
		end,
		encode = function(data: any): any
			return Deep.copy(data)
		end,
		decode = function(saved: any): any
			return Deep.copy(saved)
		end,
	}
	w.store, w.ds = StoreServer.new(w.records, w.clock, "JOB", {
		wait = function(seconds: number)
			w.sched:wait(seconds)
		end,
		resume = function(thread: thread)
			w.sched:spawn(thread)
		end,
		defaultData = profile.defaultData,
		encode = profile.encode,
		decode = profile.decode,
	})
	w.sessions = Sessions.new({
		store = w.store,
		keyFor = function(userId: number)
			return "Player_" .. userId
		end,
		present = function(player: any)
			return player.here
		end,
		kick = function(player: any, message: string)
			table.insert(w.kicks, `{player.name}: {message}`)
		end,
		playerOf = function(userId: number)
			return w.players[userId]
		end,
		ready = function() end,
		spawn = function(fn: () -> ())
			w.sched:spawn(fn)
		end,
		wait = function(seconds: number)
			w.sched:wait(seconds)
		end,
		clock = function()
			return w.clock:now()
		end,
		closeSeconds = 25,
		log = function(message: string)
			table.insert(w.logs, message)
		end,
	})
	return w
end

local function arrive(w: any, userId: number): any
	local player = { name = `p{userId}`, here = true }
	w.players[userId] = player
	w.sched:spawn(function()
		w.sessions:join(userId, player)
	end)
	return w.sessions.live[userId]
end

return {
	{
		name = "saveNow returns true once the write landed, and the stored data is the session's",
		run = function()
			local w = world()
			local session = arrive(w, 1)
			session.data.coins = 321
			session.data.lifetime.points = 2
			assert(w.sessions:saveNow(1) == true)
			assert(Deep.equal(w.records.Player_1.data, session.data), "stored equals in-memory")
			assert(w.records.Player_1.data.coins == 321)
		end,
	},
	{
		name = "saveNow is false for a player with no session",
		run = function()
			local w = world()
			assert(w.sessions:saveNow(9) == false)
		end,
	},
	{
		name = "saveNow is false when the write failed, and true again once the store works",
		run = function()
			local w = world()
			local session = arrive(w, 1)
			session.data.coins = 11
			w.ds:failNext(1, "throttled")
			assert(w.sessions:saveNow(1) == false)
			assert(session.lost == false and #w.kicks == 0, "a failed call is not a lost lease")
			assert(w.records.Player_1.data.coins ~= 11, "nothing landed")
			assert(w.sessions:saveNow(1) == true and w.records.Player_1.data.coins == 11)
		end,
	},
	{
		name = "saveNow is false on a lost lease, writes nothing and kicks the player",
		run = function()
			local w = world()
			local session = arrive(w, 1)
			w.sched:advance(181)
			local thief = StoreServer.new(w.records, w.clock, "OTHER")
			assert(thief:load("Player_1") ~= nil)
			session.data.coins = 1
			assert(w.sessions:saveNow(1) == false)
			assert(w.kicks[1] == "p1: Your data was opened on another server.", tostring(w.kicks[1]))
			assert(w.records.Player_1.data.coins ~= 1, "the other server's record is untouched")
			assert(w.sessions:saveNow(1) == false, "and it stays false")
		end,
	},
	{
		name = "saveNow is false for a read-only session and never writes it",
		run = function()
			local w = world()
			w.records.Player_1 = {
				schema = 9,
				savedAt = 0,
				data = {
					coins = 40,
					lifetime = {},
					seasons = {},
					streak = { day = 0, count = 0, earned = 0 },
					notices = {},
				},
			}
			local session = arrive(w, 1)
			session.data.coins = 9999
			assert(w.sessions:saveNow(1) == false)
			assert(w.records.Player_1.data.coins == 40)
		end,
	},
	{
		name = "an autosave racing saveNow: both land, one after the other, and the record equals memory",
		run = function()
			local w = world()
			local session = arrive(w, 1)
			session.data.coins = 100
			-- The autosave parks mid-call, after it has read the session and before it writes.
			w.ds:hookNext(function()
				w.sched:wait(5)
			end)
			w.sessions:saveAll()
			assert(session.busy == true, "the autosave is in flight")
			session.data.coins = 250
			session.data.notices[1] = { text = "season 1 paid", at = 1 }
			local before = w.ds.calls
			local result: boolean? = nil
			w.sched:spawn(function()
				result = w.sessions:saveNow(1)
			end)
			assert(result == nil, "saveNow waits behind the autosave")
			assert(w.ds.calls == before, "and has not started a second write")
			w.sched:advance(5)
			assert(result == true, "saveNow landed")
			assert(w.ds.calls == before + 1, "exactly one more write")
			assert(Deep.equal(w.records.Player_1.data, session.data), "the record equals the session")
			assert(w.records.Player_1.data.coins == 250 and w.records.Player_1.data.notices[1] ~= nil)
			assert(session.busy == false and session.lost == false)
		end,
	},
}
