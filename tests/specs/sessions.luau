--!strict
-- The session lifecycle on one server: joins, leaves, quick rejoins, autosave and shutdown.
-- A FakeScheduler stands in for task.spawn and task.wait, and the fake store's hook parks a
-- call mid-flight so a test can act while it is still running.
local Deep = require("../fakes/Deep")
local FakeClock = require("../fakes/FakeClock")
local FakeScheduler = require("../fakes/FakeScheduler")
local Config = require("../../src/shared/Config")
local Sessions = require("../../src/server/Sessions")
local StoreServer = require("../fakes/StoreServer")

local LOCKED = "Your data is still open on another server. Rejoin in a minute."
local LOST = "Your data was opened on another server."

local function world(records: any?): any
	-- inUse[userId] = true stands in for a score or reward call that is still running for that player.
	local w: any = { records = records or {}, kicks = {}, players = {}, logs = {}, inUse = {} }
	w.clock = FakeClock.new(0)
	w.sched = FakeScheduler.new(w.clock)
	-- The saved shape, kept inline so these specs only need the data layer: a new profile holds the
	-- starting coins, and encode and decode copy every field.
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
		inUse = function(userId: number): boolean
			return w.inUse[userId] == true
		end,
	})
	return w
end

local function arrive(w: any, userId: number, name: string): any
	local player = { name = name, here = true }
	w.players[userId] = player
	w.sched:spawn(function()
		w.sessions:join(userId, player)
	end)
	return player
end

local function depart(w: any, userId: number)
	local player = w.players[userId]
	player.here = false
	w.players[userId] = nil
	w.sessions:leave(userId)
end

local function parkNextCall(w: any, seconds: number)
	w.ds:hookNext(function()
		w.sched:wait(seconds)
	end)
end

local function oldBag(schema: number): any
	return {
		schema = schema,
		savedAt = 0,
		data = {
			coins = 40,
			lifetime = {},
			seasons = {},
			streak = { day = 0, count = 0, earned = 0 },
			notices = {},
		},
	}
end

return {
	{
		name = "a player who rejoins while their release is in flight waits for it and loads what it wrote",
		run = function()
			local w = world()
			arrive(w, 1, "first")
			local old = w.sessions.live[1]
			assert(old ~= nil)
			old.data.coins = 7
			parkNextCall(w, 5)
			depart(w, 1) -- the release is now parked mid-call
			arrive(w, 1, "second")
			assert(w.sessions.live[1] == nil, "the new join waits")
			assert(w.records.Player_1.lease.owner == old.owner, "the old release hasn't landed yet")
			w.sched:advance(6)
			local new = w.sessions.live[1]
			assert(new ~= nil and new ~= old, "the rejoin has its own session")
			assert(new.data.coins == 7, "holding what the old session wrote")
			assert(w.records.Player_1.lease.owner == new.owner)
			assert(#w.kicks == 0, w.kicks[1])
			-- control: with nothing in flight, a rejoin loads straight away
			depart(w, 1)
			arrive(w, 1, "third")
			assert(w.sessions.live[1] ~= nil and w.sessions.live[1] ~= new)
		end,
	},
	{
		name = "a rejoin during a slow load gets the record, and the departed load is handed back",
		run = function()
			local w = world()
			parkNextCall(w, 5) -- the first load's claim is slow
			local first = arrive(w, 1, "first")
			assert(w.sessions.live[1] == nil)
			first.here = false -- they leave before it finishes
			w.players[1] = nil
			w.sessions:leave(1)
			arrive(w, 1, "second")
			w.sched:advance(6)
			local session = w.sessions.live[1]
			assert(session ~= nil, "the second join has a session")
			assert(w.records.Player_1.lease.owner == session.owner, "and holds the lease")
			session.data.coins = 3
			assert(session:save() == true and w.records.Player_1.data.coins == 3)
			assert(#w.kicks == 0, w.kicks[1])
		end,
	},
	{
		name = "a load for a player who left stops retrying",
		run = function()
			local records: any = {}
			local w = world(records)
			local other = StoreServer.new(records, w.clock, "OTHER")
			assert(other:load("Player_1") ~= nil) -- another server holds the record
			local first = arrive(w, 1, "first")
			assert(w.ds.calls == 1, "first attempt held, now waiting")
			first.here = false
			w.sched:advance(10)
			assert(w.ds.calls == 1, `no more attempts once the player left, calls={w.ds.calls}`)
			assert(#w.kicks == 0)
			-- control: a player who stays is retried and then told
			arrive(w, 1, "second")
			w.sched:advance(10)
			assert(w.ds.calls == 4, `calls={w.ds.calls}`)
			assert(w.kicks[1] == "second: " .. LOCKED, w.kicks[1])
		end,
	},
	{
		name = "close waits for a load still in flight and hands its lease back",
		run = function()
			local w = world()
			parkNextCall(w, 5)
			arrive(w, 1, "first")
			local closedAt: number? = nil
			w.sched:spawn(function()
				w.sessions:close()
				closedAt = w.clock:now()
			end)
			assert(closedAt == nil, "close waits for the load")
			w.sched:advance(10)
			assert(closedAt ~= nil and closedAt >= 5 and closedAt < 6, tostring(closedAt))
			assert(w.records.Player_1.lease == nil, "the late load was handed back")
			assert(w.sessions.live[1] == nil)
			-- control: with nothing in flight close returns straight away
			local w2 = world()
			local done = false
			w2.sched:spawn(function()
				w2.sessions:close()
				done = true
			end)
			assert(done)
		end,
	},
	{
		name = "close releases every session and waits no longer than its timeout",
		run = function()
			local w = world()
			arrive(w, 1, "a")
			arrive(w, 2, "b")
			w.sessions.live[1].data.coins = 1
			w.sessions.live[2].data.coins = 2
			parkNextCall(w, 100) -- one release hangs
			local closedAt: number? = nil
			w.sched:spawn(function()
				w.sessions:close()
				closedAt = w.clock:now()
			end)
			w.sched:advance(30)
			assert(closedAt ~= nil and closedAt >= 25 and closedAt < 25.2, tostring(closedAt))
			local released = 0
			for _, key in { "Player_1", "Player_2" } do
				if w.records[key].lease == nil then
					released += 1
				end
			end
			assert(released == 1, `one release landed, the other hung, got {released}`)
			-- control: without the hang both land and close returns at once
			local w2 = world()
			arrive(w2, 1, "a")
			arrive(w2, 2, "b")
			local done = false
			w2.sched:spawn(function()
				w2.sessions:close()
				done = true
			end)
			assert(done and w2.records.Player_1.lease == nil and w2.records.Player_2.lease == nil)
		end,
	},
	{
		name = "a read-only session can be shown but not changed, and a lost one is kicked",
		run = function()
			local w = world({ Player_1 = oldBag(9) })
			arrive(w, 1, "a")
			arrive(w, 2, "b")
			assert(w.sessions:get(1) ~= nil, "a read-only session can still be shown")
			assert(w.sessions:writable(1) == false and w.sessions:writableSession(1) == nil)
			assert(w.sessions:writable(2) == true, "control: a current record can change")
			assert(w.sessions:writableSession(2) == w.sessions:get(2))
			-- player 2's lease runs out and another server takes the record
			w.sched:advance(181)
			local thief = StoreServer.new(w.records, w.clock, "OTHER")
			assert(thief:load("Player_2") ~= nil)
			w.sessions:saveAll()
			assert(w.kicks[1] == "b: " .. LOST and #w.kicks == 1, w.kicks[1])
			assert(w.sessions:writable(2) == false and w.sessions:get(2) == nil)
			assert(w.sessions:writableSession(2) == nil)
			assert(w.records.Player_2.lease.owner ~= w.sessions.live[2].owner, "nothing was written")
		end,
	},
	{
		name = "a read-only session is never written back, by autosave or on release",
		run = function()
			local w = world({ Player_1 = oldBag(9) })
			arrive(w, 1, "a")
			w.sessions:get(1).data.coins = 9999 -- a bug that changes it anyway
			w.sessions:saveAll()
			depart(w, 1)
			assert(w.records.Player_1.data.coins == 40, "the newer record is untouched")
			assert(w.records.Player_1.schema == 9 and w.records.Player_1.lease == nil)
			-- control: a current record is written back
			local w2 = world({ Player_1 = oldBag(1) })
			arrive(w2, 1, "a")
			w2.sessions:get(1).data.coins = 55
			depart(w2, 1)
			assert(w2.records.Player_1.data.coins == 55)
		end,
	},
	{
		name = "a leave waits for a score or reward call still running, then saves what it finished with",
		run = function()
			local w = world()
			arrive(w, 1, "a")
			local session = w.sessions.live[1]
			w.inUse[1] = true -- a sell is waiting on the wallet
			depart(w, 1)
			w.sched:advance(5)
			assert(w.records.Player_1.lease ~= nil, "not released while the call runs")
			session.data.coins = 440 -- the call finishes
			w.inUse[1] = nil
			w.sched:advance(1)
			assert(w.records.Player_1.lease == nil, "released once it finished")
			assert(w.records.Player_1.data.coins == 440, "with what the call wrote")
			assert(#w.logs == 0, w.logs[1])
			-- control: a call that never finishes holds the release up for closeSeconds, no longer
			local w2 = world()
			arrive(w2, 1, "a")
			w2.inUse[1] = true
			depart(w2, 1)
			w2.sched:advance(24.5)
			assert(w2.records.Player_1.lease ~= nil)
			w2.sched:advance(1)
			assert(w2.records.Player_1.lease == nil, "released at the bound anyway")
			assert(#w2.logs == 1 and string.find(w2.logs[1], "still running", 1, true), w2.logs[1])
		end,
	},
	{
		name = "close waits for a score or reward call still running before it releases",
		run = function()
			local w = world()
			arrive(w, 1, "a")
			local session = w.sessions.live[1]
			w.inUse[1] = true
			local closedAt: number? = nil
			w.sched:spawn(function()
				w.sessions:close()
				closedAt = w.clock:now()
			end)
			w.sched:advance(3)
			assert(closedAt == nil and w.records.Player_1.lease ~= nil, "close is waiting on the call")
			session.data.coins = 380
			w.inUse[1] = nil
			w.sched:advance(1)
			assert(closedAt ~= nil and closedAt < 4, tostring(closedAt))
			assert(w.records.Player_1.lease == nil and w.records.Player_1.data.coins == 380)
		end,
	},
}
