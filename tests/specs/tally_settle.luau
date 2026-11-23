--!strict
-- Tally.settle over a FakeDataStore handle for the seasons, a Leaderboard over a FakeOrderedDataStore,
-- a stub profiles table whose save counts calls, and the real pure modules. Season 1 is [1000, 1100),
-- and a close is judged by a clock CloseGraceSeconds (60) behind the server's.
local Config = require("../../src/shared/Config")
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

local GRACE = Config.CloseGraceSeconds
local WAIT = Config.PodiumWaitSeconds

local function newProfile(scores: { [string]: number }?): any
	local seasons: any = {}
	for key, score in scores or {} do
		seasons[key] = { score = score, rewarded = false }
	end
	return {
		coins = 0,
		lifetime = {},
		seasons = seasons,
		streak = { day = 0, count = 0, earned = 0 },
		notices = {},
	}
end

local function build(options: any?): any
	local opts = options or {}
	local w: any = {}
	w.clock = FakeClock.new(opts.start or 1200)
	w.records = opts.records or {}
	w.ds = FakeDataStore.new(w.records)
	w.faults = Faults.new()
	w.handle = w.ds:handle(w.faults)
	w.ordered = FakeOrderedDataStore.new(w.clock, 0)
	w.orderedHandle = w.ordered:handle(Faults.new())
	w.boardDown = false
	local board: any = {
		SetAsync = function(_: any, key: string, value: number)
			w.orderedHandle:SetAsync(key, value)
		end,
		GetSortedAsync = function(_: any, ...: any)
			if w.boardDown then
				error("ordered store is down")
			end
			return w.orderedHandle:GetSortedAsync(...)
		end,
	}
	w.logs = {}
	local function log(message: string)
		table.insert(w.logs, message)
	end
	w.board = Leaderboard.new({
		store = function(_: number): any
			return board
		end,
		now = function(): number
			return w.clock:now()
		end,
		size = 10,
		refreshSeconds = 15,
		log = log,
	})
	w.live = {} :: { [number]: any }
	w.saves = 0
	w.failSave = false
	w.config = Deep.copy(Config)
	w.config.Epoch = 1000
	if opts.grace ~= nil then
		w.config.CloseGraceSeconds = opts.grace
	end
	w.tally = Tally.new({
		seasons = w.handle,
		leaderboard = w.board,
		profiles = {
			get = function(userId: number): any
				return w.live[userId]
			end,
			save = function(_: number, _staked: any): boolean
				w.saves += 1
				if w.parkSave then
					w.parkSave = false
					coroutine.yield()
				end
				return not w.failSave
			end,
		},
		now = function(): number
			return math.floor(w.clock:now())
		end,
		serverId = opts.serverId or "A",
		length = opts.length or 100,
		config = w.config,
		Season = Season,
		Scores = Scores,
		Payout = Payout,
		Notices = Notices,
		Streak = Streak,
		log = log,
	})
	return w
end

-- A world with player 1 holding `scores`, and the board showing the given players' scores.
local function world(scores: { [string]: number }?, board: { [number]: number }?, options: any?): any
	local w = build(options)
	w.live[1] = newProfile(scores or { ["1"] = 60 })
	-- Written at time 0, so the board reads the same whatever time the spec then sets.
	local at = w.clock.t
	w.clock.t = 0
	for userId, score in board or { [1] = 60, [2] = 40 } do
		w.ordered:write(tostring(userId), score)
	end
	w.clock.t = at
	return w
end

local function logged(w: any, text: string): number
	local n = 0
	for _, line in w.logs do
		if string.find(line, text, 1, true) then
			n += 1
		end
	end
	return n
end

-- An open season key, as a tick would have left it.
local function storeOpen(w: any, id: number, endsAt: number?)
	local startsAt, ends = Season.window(1000, 100, id)
	w.records[Season.key(id)] = Season.open(nil, id, startsAt, endsAt or ends)
end

-- Runs settle in its own thread, so a parked read leaves it suspended for the spec to resume.
local function settleAsync(w: any, userId: number): any
	local run: any = { paid = nil }
	run.co = coroutine.create(function()
		run.paid = w.tally:settle(userId)
	end)
	local ok, err = coroutine.resume(run.co)
	assert(ok, err)
	return run
end

local function resume(run: any)
	local ok, err = coroutine.resume(run.co)
	assert(ok, err)
end

-- The next read of the season store parks the calling thread until the spec resumes it.
local function parkNextRead(w: any)
	w.faults.onRead = function()
		w.faults.onRead = nil
		coroutine.yield()
	end
end

return {
	{
		name = "settle reads the missing key, opens it, closes it with the board's top, and pays the tier plus the podium bonus",
		run = function()
			local w = world()
			local paid = w.tally:settle(1)
			assert(paid == 1, `paid {paid}`)
			local profile = w.live[1]
			assert(profile.coins == 450, `coins {profile.coins}`)
			assert(
				Deep.equal(
					profile.seasons["1"],
					{ score = 60, rewarded = true, tier = "Silver", reward = 450 }
				)
			)
			assert(#profile.notices == 1)
			assert(
				profile.notices[1].text
					== "Season 1 is over. You scored 60 points, reached Silver and placed 1st on the podium. 450 Coins paid.",
				profile.notices[1].text
			)
			local stored = w.records["season/1"]
			assert(stored.state == "closed" and stored.closedBy == "A", "closed by this server")
			assert(stored.startsAt == 1000 and stored.endsAt == 1100)
			assert(Deep.equal(stored.podium, { { userId = 1, score = 60 }, { userId = 2, score = 40 } }))
			assert(w.ds.calls == 2, `{w.ds.calls} season writes: the open and the close`)
		end,
	},
	{
		name = "a player who is off the podium is paid the tier only",
		run = function()
			local w = world({ ["1"] = 60 }, { [2] = 90, [3] = 80, [4] = 70, [1] = 60 })
			assert(w.tally:settle(1) == 1)
			assert(w.live[1].coins == 150, `coins {w.live[1].coins}`)
			assert(w.live[1].seasons["1"].reward == 150)
		end,
	},
	{
		name = "settle in the current season pays nothing and writes nothing",
		run = function()
			local w = world(nil, nil, { start = 1050 })
			assert(w.tally:settle(1) == 0)
			assert(w.live[1].coins == 0 and w.saves == 0 and w.ds.calls == 0)
			assert(w.records["season/1"] == nil)
		end,
	},
	{
		name = "a stored key whose end is not the config's is refused, not closed early: nothing is written and nothing paid",
		run = function()
			local w = world()
			storeOpen(w, 1, 5000)
			assert(w.tally:settle(1) == 0)
			assert(w.ds.calls == 0, "no close write")
			assert(w.records["season/1"].state == "open" and w.live[1].coins == 0 and w.saves == 0)
			assert(logged(w, "does not match") == 1, table.concat(w.logs, "; "))
			w.clock.t = 5000 + GRACE
			assert(w.tally:settle(1) == 0, "the key's own end does not make it closable")
			assert(w.records["season/1"].state == "open" and w.ds.calls == 0)
		end,
	},
	{
		name = "settle twice pays once",
		run = function()
			local w = world()
			assert(w.tally:settle(1) == 1)
			assert(w.tally:settle(1) == 0)
			assert(w.live[1].coins == 450 and #w.live[1].notices == 1 and w.saves == 1)
		end,
	},
	{
		name = "a second settle while one is parked in the season read returns 0 at once, and the first pays once",
		run = function()
			local w = world()
			parkNextRead(w)
			local first = settleAsync(w, 1)
			assert(first.paid == nil, "the first is parked")
			assert(w.tally:settle(1) == 0, "the lock: the second returns at once")
			assert(w.saves == 0 and w.live[1].coins == 0, "the second paid nothing")
			resume(first)
			assert(first.paid == 1, `the first paid {first.paid}`)
			assert(w.live[1].coins == 450 and #w.live[1].notices == 1 and w.saves == 1)
			assert(w.tally:settle(1) == 0, "and the lock was released")
		end,
	},
	{
		name = "a season key that already holds a rival close pays from the stored podium, read at the top",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.records["season/1"] =
				Season.close(w.records["season/1"], 1100, { { userId = 2, score = 99 } }, "B")
			assert(w.tally:settle(1) == 1)
			assert(w.live[1].coins == 150, `tier only, not on the stored podium: {w.live[1].coins}`)
			assert(w.records["season/1"].closedBy == "B" and w.ds.calls == 0)
		end,
	},
	{
		name = "a rival that closes between this server's read and its close write wins, and this server pays from its podium",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.ds:hookNext(function()
				w.records["season/1"] =
					Season.close(w.records["season/1"], 1100, { { userId = 2, score = 99 } }, "B")
			end)
			assert(w.tally:settle(1) == 1)
			assert(w.records["season/1"].closedBy == "B", "the first close won")
			assert(w.live[1].coins == 150, `paid from the stored podium: {w.live[1].coins}`)
		end,
	},
	{
		name = "a failed payout save rolls the profile back, logs, pays nothing, and the next settle pays once",
		run = function()
			local w = world()
			storeOpen(w, 1)
			local before = Deep.copy(w.live[1])
			w.failSave = true
			assert(w.tally:settle(1) == 0)
			assert(Deep.equal(w.live[1], before), "back to exactly its earlier state, notice removed")
			assert(logged(w, "payout save failed for 1") == 1)
			assert(w.saves == 1)
			w.failSave = false
			assert(w.tally:settle(1) == 1)
			assert(w.live[1].coins == 450 and #w.live[1].notices == 1)
			assert(w.tally:settle(1) == 0 and w.live[1].coins == 450)
		end,
	},
	{
		name = "a failed payout save rolls back relative to the current values, keeping a change made while it was in flight",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.parkSave = true
			local run = settleAsync(w, 1)
			assert(run.paid == nil and w.live[1].coins == 450, "parked in the payout save, payout applied")
			-- Meanwhile something else changes the profile, as a streak claim would.
			w.live[1].coins += 5
			table.insert(w.live[1].notices, { text = "Streak claimed.", at = 1 })
			w.failSave = true
			resume(run)
			assert(run.paid == 0, `paid {run.paid}`)
			local profile = w.live[1]
			assert(profile.coins == 5, `the payout is removed and the 5 kept: {profile.coins}`)
			assert(
				#profile.notices == 1 and profile.notices[1].text == "Streak claimed.",
				"only the other notice"
			)
			assert(profile.seasons["1"].rewarded == false and profile.seasons["1"].reward == nil)
			w.failSave = false
			assert(w.tally:settle(1) == 1)
			assert(profile.coins == 455 and #profile.notices == 2, `coins {profile.coins}`)
			assert(w.tally:settle(1) == 0 and profile.coins == 455)
		end,
	},
	{
		name = "a season key write that raises on the open is logged, pays nothing, and the next settle completes",
		run = function()
			local w = world()
			w.ds:failNext(1, "boom")
			assert(w.tally:settle(1) == 0)
			assert(logged(w, "season 1 open failed") == 1, table.concat(w.logs, "; "))
			assert(w.live[1].coins == 0 and w.saves == 0 and w.records["season/1"] == nil)
			assert(w.tally:settle(1) == 1)
			assert(w.live[1].coins == 450 and w.records["season/1"].state == "closed")
		end,
	},
	{
		name = "a season key write that raises on the close is logged, pays nothing, and the next settle completes",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.ds:failNext(1, "boom")
			assert(w.tally:settle(1) == 0)
			assert(logged(w, "season 1 close failed") == 1, table.concat(w.logs, "; "))
			assert(w.records["season/1"].state == "open" and w.live[1].coins == 0 and w.saves == 0)
			assert(w.tally:settle(1) == 1)
			assert(w.live[1].coins == 450 and w.records["season/1"].state == "closed")
		end,
	},
	{
		name = "a board that is down at the close waits, then closes without a podium once it has stayed down for the wait",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.boardDown = true
			local firstFail = 1100 + GRACE + 1
			w.clock.t = firstFail
			assert(w.tally:settle(1) == 0)
			assert(w.ds.calls == 0 and w.records["season/1"].state == "open", "no close write")
			assert(logged(w, "waiting") == 1 and logged(w, "closing without one") == 0)
			assert(w.saves == 0 and w.live[1].coins == 0)

			w.clock.t = firstFail + WAIT - 1
			assert(w.tally:settle(1) == 0, "still waiting one second before the wait runs out")
			assert(logged(w, "waiting") == 1, "the wait is logged once per season, not on every poll")
			assert(w.records["season/1"].state == "open")

			w.clock.t = firstFail + WAIT
			assert(w.tally:settle(1) == 1)
			local stored = w.records["season/1"]
			assert(stored.state == "closed" and #stored.podium == 0, "closed with an empty podium")
			assert(w.live[1].coins == 150, `the tier only: {w.live[1].coins}`)
			assert(logged(w, "closing without one") == 1)
		end,
	},
	{
		-- The wait is measured from the first failed read, not from the season's end: a first
		-- player who joins hours after the end and meets one failed read must not freeze an empty
		-- podium for everyone.
		name = "a season that ended long ago waits for the board from the first failed read, not from its end, and closes with the real podium",
		run = function()
			local w = world(nil, nil, { start = 1100 + 7200 })
			storeOpen(w, 1)
			w.boardDown = true
			assert(w.tally:settle(1) == 0, "the one failed read waits")
			assert(w.records["season/1"].state == "open" and w.ds.calls == 0, "no close written")
			assert(logged(w, "closing without one") == 0, table.concat(w.logs, "; "))
			w.boardDown = false
			w.clock.t += 30
			assert(w.tally:settle(1) == 1)
			assert(#w.records["season/1"].podium == 2, "the real podium, not an empty one")
			assert(w.live[1].coins == 450)
			assert(logged(w, "closing without one") == 0)
		end,
	},
	{
		name = "a board read that succeeds clears the failure, so a later outage waits the whole time again",
		run = function()
			local w = world(nil, nil, { start = 1100 + GRACE })
			storeOpen(w, 1)
			w.boardDown = true
			assert(w.tally:settle(1) == 0)
			w.boardDown = false
			w.clock.t += WAIT / 2
			-- The board answers, but the close write itself fails: nothing is written.
			w.ds:failNext(1, "boom")
			assert(w.tally:settle(1) == 0)
			w.boardDown = true
			w.clock.t += WAIT / 2 + 1
			assert(w.tally:settle(1) == 0, "the outage that began after the good read has not run out")
			assert(w.records["season/1"].state == "open")
			assert(logged(w, "closing without one") == 0, table.concat(w.logs, "; "))
		end,
	},
	{
		name = "a board that comes back before the wait has run out closes with the real podium",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.boardDown = true
			w.clock.t = 1100 + GRACE + 1
			assert(w.tally:settle(1) == 0)
			w.boardDown = false
			w.clock.t += 30
			assert(w.tally:settle(1) == 1)
			assert(#w.records["season/1"].podium == 2, "the real podium")
			assert(w.live[1].coins == 450)
			assert(logged(w, "closing without one") == 0)
		end,
	},
	{
		name = "a close waits for the grace period by this server's clock, and happens at its end",
		run = function()
			local w = world()
			storeOpen(w, 1)
			w.clock.t = 1100 + GRACE - 1
			assert(w.tally:settle(1) == 0)
			assert(w.ds.calls == 0 and w.records["season/1"].state == "open", "no close write")
			assert(w.saves == 0)
			w.clock.t = 1100 + GRACE
			assert(w.tally:settle(1) == 1)
			assert(w.records["season/1"].state == "closed")
			assert(w.records["season/1"].closedAt == 1100, "stamped with the grace-adjusted clock")
			assert(w.live[1].coins == 450, "paid from the podium the board gave")
		end,
	},
	{
		name = "exactly one profile save per paid season, and none for a skip, a wait or a refused close",
		run = function()
			local w = world()
			assert(w.tally:settle(1) == 1)
			assert(w.saves == 1, `{w.saves} saves for one paid season`)

			local skipped = world(nil, nil, { start = 1050 })
			skipped.tally:settle(1)
			assert(skipped.saves == 0)

			local waiting = world()
			storeOpen(waiting, 1, 5000)
			waiting.tally:settle(1)
			assert(waiting.saves == 0)

			local refused = world()
			storeOpen(refused, 1)
			refused.ds:failNext(1, "boom")
			refused.tally:settle(1)
			assert(refused.saves == 0)
		end,
	},
	{
		name = "seasons 1, 2 and 4 unpaid and 3 unscored settle 1, 2 and 4 in that order in one call, in three saves",
		run = function()
			local w = world({ ["4"] = 20, ["1"] = 20, ["3"] = 0, ["2"] = 20 }, { [2] = 30 })
			w.clock.t = 1800
			assert(w.tally:settle(1) == 3)
			assert(w.saves == 3, `{w.saves} saves`)
			local notices = w.live[1].notices
			assert(#notices == 3)
			for i, id in { 1, 2, 4 } do
				assert(string.find(notices[i].text, `Season {id} is over`, 1, true), notices[i].text)
				assert(w.live[1].seasons[tostring(id)].rewarded == true)
			end
			assert(w.live[1].seasons["3"].rewarded == false and w.records["season/3"] == nil)
			assert(w.live[1].coins == 150, `three Bronze payouts: {w.live[1].coins}`)
		end,
	},
	{
		name = "a season paid meanwhile, while the season read was parked, is not paid again",
		run = function()
			local w = world()
			parkNextRead(w)
			local run = settleAsync(w, 1)
			assert(run.paid == nil, "parked")
			w.live[1].seasons["1"].rewarded = true
			resume(run)
			assert(run.paid == 0, `paid {run.paid}`)
			assert(w.live[1].coins == 0 and w.saves == 0 and #w.live[1].notices == 0)
		end,
	},
	{
		-- SeasonLengthSeconds doubled on a live game: season 3 is [1400, 1600) now, but the stored
		-- key was made under length 100, [1200, 1300). A closed key from the old numbering must not
		-- pay a score earned in the new one.
		name = "a season key whose window is not the config's is not paid from, and says so",
		run = function()
			local w = world({ ["3"] = 60 }, nil, { start = 2000, length = 200 })
			w.records["season/3"] = Season.close(Season.open(nil, 3, 1200, 1300), 1300, {}, "X")
			assert(w.tally:currentId() == 6)
			assert(w.tally:settle(1) == 0, "nothing is paid")
			assert(w.live[1].coins == 0 and w.saves == 0 and #w.live[1].notices == 0)
			assert(w.live[1].seasons["3"].rewarded == false, "the score stays unpaid for the operator")
			assert(logged(w, "does not match") == 1, table.concat(w.logs, "; "))
			assert(w.tally:settle(1) == 0 and logged(w, "does not match") == 1, "once per season")
			assert(w.records["season/3"].endsAt == 1300, "the key is untouched")
		end,
	},
	{
		name = "settle never throws: a raise is logged and returns 0",
		run = function()
			local w = world()
			w.live[1].seasons = nil
			assert(w.tally:settle(1) == 0)
			assert(logged(w, "settle failed for 1:") == 1, table.concat(w.logs, "; "))
			w.live[1].seasons = {}
			assert(w.tally:settle(1) == 0, "the lock was released after the raise")
		end,
	},
}
