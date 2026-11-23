--!strict
-- Tally over a FakeDataStore handle for the seasons, a Leaderboard over FakeOrderedDataStore, an
-- in-memory profiles table and the real pure modules. Season 1 is [1000, 1100).
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

local function newProfile(): any
	return {
		coins = 0,
		lifetime = {},
		seasons = {},
		streak = { day = 0, count = 0, earned = 0 },
		notices = {},
	}
end

local function build(options: any?): any
	local opts = options or {}
	local w: any = {}
	w.clock = opts.clock or FakeClock.new(1000)
	w.records = opts.records or {}
	w.ds = FakeDataStore.new(w.records)
	w.faults = Faults.new()
	w.handle = w.ds:handle(w.faults)
	w.ordered = opts.ordered or FakeOrderedDataStore.new(w.clock, 0)
	w.orderedHandle = w.ordered:handle(Faults.new())
	w.orderedWrites = 0
	w.writtenSeasons = {} -- the season id of each ordered write, in order
	local function counted(id: number): any
		return {
			SetAsync = function(_: any, key: string, value: number)
				w.orderedWrites += 1
				table.insert(w.writtenSeasons, id)
				w.orderedHandle:SetAsync(key, value)
			end,
			GetSortedAsync = function(_: any, ...: any)
				return w.orderedHandle:GetSortedAsync(...)
			end,
		}
	end
	w.logs = {}
	local function log(message: string)
		table.insert(w.logs, message)
	end
	w.board = Leaderboard.new({
		store = counted,
		now = function(): number
			return w.clock:now()
		end,
		size = 10,
		refreshSeconds = 15,
		log = log,
	})
	w.live = {} -- userId -> profile
	w.saves = 0
	w.config = {
		Epoch = 1000,
		ScoreMode = "sum",
		ScoreStat = "points",
		MaxPointsPerCall = 1000,
		CloseGraceSeconds = 60,
	}
	w.tally = Tally.new({
		seasons = w.handle,
		leaderboard = w.board,
		profiles = {
			get = function(userId: number): any
				return w.live[userId]
			end,
			save = function(_: number, _staked: any): boolean
				w.saves += 1
				return true
			end,
		},
		now = function(): number
			return math.floor(w.clock:now() + (opts.skew or 0))
		end,
		serverId = opts.serverId or "A",
		readOptions = { UseCache = false },
		length = 100,
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

local function count(t: any): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- Another server closes the stored season key.
local function closeStored(w: any, id: number, at: number)
	local current = w.records[Season.key(id)]
	local closed = Season.close(current, at, {}, "B")
	assert(closed ~= nil, "the season could be closed")
	w.records[Season.key(id)] = closed
end

return {
	{
		name = "currentId is nil before the epoch, 1 at the epoch and 2 at the next window",
		run = function()
			local w = build()
			w.clock.t = 999
			assert(w.tally:currentId() == nil)
			w.clock.t = 1000
			assert(w.tally:currentId() == 1)
			w.clock.t = 1099
			assert(w.tally:currentId() == 1)
			w.clock.t = 1100
			assert(w.tally:currentId() == 2)
		end,
	},
	{
		name = "ensureOpen writes the season key once, remembers it, and two servers leave one key",
		run = function()
			local w = build()
			local opened = w.tally:ensureOpen(1)
			assert(
				opened ~= nil and opened.state == "open" and opened.startsAt == 1000 and opened.endsAt == 1100
			)
			assert(w.records["season/1"].state == "open")
			local again = w.tally:ensureOpen(1)
			assert(again ~= nil and again.endsAt == 1100, "a second call returns what is stored")
			assert(w.records["season/1"].startsAt == 1000 and count(w.records) == 1, "and changes nothing")
			assert(w.tally.known[1] ~= nil and w.tally.known[1].state == "open", "known holds it")

			-- two servers at once: B opens it between A's read and write
			local a = build({ serverId = "A" })
			local b = build({ serverId = "B", records = a.records, clock = a.clock })
			a.ds:hookNext(function()
				b.tally:ensureOpen(1)
			end)
			a.tally:ensureOpen(1)
			assert(count(a.records) == 1 and a.records["season/1"].state == "open", "one key")
			assert(a.tally.known[1] ~= nil and b.tally.known[1] ~= nil)
		end,
	},
	{
		name = "tick opens the current season and sees a close made by another server on the next tick",
		run = function()
			local w = build()
			w.clock.t = 1050
			assert(w.tally:tick() == 1)
			assert(w.records["season/1"] ~= nil and w.tally.known[1].state == "open")
			closeStored(w, 1, 1100)
			assert(w.tally.known[1].state == "open", "not seen until the next tick")
			w.tally:tick()
			assert(w.tally.known[1].state == "closed", "the stored close wins")
			w.clock.t = 900
			assert(w.tally:tick() == nil, "before the epoch there is nothing to open")
		end,
	},
	{
		name = "record raises the live profile and writes nothing, and refuses each bad case",
		run = function()
			local w = build()
			w.live[1] = newProfile()
			w.tally:tick()
			local ds, saves, ordered = w.ds.calls, w.saves, w.orderedWrites
			local ok, why = w.tally:record(1, 30)
			assert(ok and why == nil, tostring(why))
			assert(w.tally:record(1, 5))
			assert(w.live[1].seasons["1"].score == 35 and w.live[1].lifetime.points == 35)
			assert(
				w.ds.calls == ds and w.saves == saves and w.orderedWrites == ordered,
				"no store was touched"
			)

			local _, bad = w.tally:record(1, 0)
			assert(bad == "bad_points", tostring(bad))
			local _, fractional = w.tally:record(1, 1.5)
			assert(fractional == "bad_points")
			local _, none = w.tally:record(2, 5)
			assert(none == "no_profile", tostring(none))

			w.live[1].seasons["1"].rewarded = true
			local _, paid = w.tally:record(1, 5)
			assert(paid == "already_rewarded", tostring(paid))
			w.live[1].seasons["1"].rewarded = false

			w.clock.t = 999
			local _, early = w.tally:record(1, 5)
			assert(early == "no_season", tostring(early))
			assert(w.live[1].seasons["1"].score == 35, "no refusal changed the score")
		end,
	},
	{
		name = "record refuses season_ended when the stored window has passed, and closed once the tick saw the stored close",
		run = function()
			local w = build()
			w.live[1] = newProfile()
			w.tally:tick()
			-- The clock alone cannot get here (the current id rolls over at the end), so the stored
			-- window is the one that has passed: a key whose endsAt is behind this server's clock.
			w.tally.known[1] = { endsAt = 1000, state = "open" }
			w.clock.t = 1050
			local _, ended = w.tally:record(1, 1)
			assert(ended == "season_ended", tostring(ended))

			local fresh = build()
			fresh.live[1] = newProfile()
			fresh.clock.t = 1050
			fresh.tally:tick()
			assert(fresh.tally:record(1, 1), "control: open and in window")
			closeStored(fresh, 1, 1100)
			fresh.tally:tick() -- sees the stored close
			local _, closed = fresh.tally:record(1, 1)
			assert(closed == "closed", tostring(closed))
			assert(fresh.live[1].seasons["1"].score == 1)
		end,
	},
	{
		name = "a server 5 seconds behind accepts a late score while the season is stored open, and refuses it once its tick reads the close",
		run = function()
			local w = build({ skew = -5 })
			w.live[1] = newProfile()
			w.clock.t = 1050
			w.tally:tick()
			w.clock.t = 1102 -- real time; this server's clock says 1097
			assert(w.tally:currentId() == 1, "its clock still says season 1")
			assert(w.tally:record(1, 7), "accepted: bounded by the stored close, not by the clock")
			closeStored(w, 1, 1102)
			w.tally:tick()
			local ok, why = w.tally:record(1, 7)
			assert(not ok and why == "closed", tostring(why))
			assert(w.live[1].seasons["1"].score == 7)
		end,
	},
	{
		name = "push writes the season score once, nothing again without a change, and nothing without an entry",
		run = function()
			local w = build()
			w.live[1] = newProfile()
			w.live[2] = newProfile()
			w.tally:tick()
			assert(w.tally:record(1, 30))
			assert(w.tally:push(1))
			assert(w.orderedWrites == 1 and w.ordered.current["1"] == 30)
			assert(w.tally:push(1))
			assert(w.orderedWrites == 1, "no change, no write")
			assert(w.tally:record(1, 5))
			assert(w.tally:push(1) and w.orderedWrites == 2 and w.ordered.current["1"] == 35)
			assert(w.tally:push(2))
			assert(w.orderedWrites == 2 and w.ordered.current["2"] == nil, "no season entry, no write")
			assert(not w.tally:push(3), "no live profile")
		end,
	},
	{
		-- The last push interval of a season: a score made at endsAt-1 is only in memory when the
		-- clock turns, so the push that follows must still write it to the season it belongs to.
		name = "push also writes the previous season's score until it is known closed and past the grace, and not once paid",
		run = function()
			local w = build()
			w.live[1] = newProfile()
			w.clock.t = 1099
			w.tally:tick()
			assert(w.tally:record(1, 40))
			w.clock.t = 1100
			assert(w.tally:currentId() == 2)
			assert(w.tally:push(1))
			assert(w.ordered.current["1"] == 40 and w.writtenSeasons[1] == 1, "season 1's board has it")
			assert(w.tally:push(1) and w.orderedWrites == 1, "the same score is not written twice")
			w.tally:tick()
			w.tally:ensureOpen(1)
			closeStored(w, 1, 1160)
			w.tally:read(1)
			w.live[1].seasons["1"].score = 55 -- a late change in the profile of the closed season
			w.clock.t = 1100 + 59
			assert(
				w.tally:push(1) and w.orderedWrites == 2,
				"within the grace a closed season is still pushed"
			)
			w.clock.t = 1100 + 60
			w.live[1].seasons["1"].score = 56
			assert(w.tally:push(1) and w.orderedWrites == 2, "known closed and past the grace: not pushed")
			-- a paid season is never pushed again
			local w2 = build()
			w2.live[1] = newProfile()
			w2.clock.t = 1099
			w2.tally:tick()
			assert(w2.tally:record(1, 40))
			w2.live[1].seasons["1"].rewarded = true
			w2.clock.t = 1110
			assert(w2.tally:push(1) and w2.orderedWrites == 0, "rewarded: nothing to push")
			-- the season before the previous one is not pushed
			local w3 = build()
			w3.live[1] = newProfile()
			w3.clock.t = 1099
			w3.tally:tick()
			assert(w3.tally:record(1, 40))
			w3.clock.t = 1210
			assert(w3.tally:push(1) and w3.orderedWrites == 0, "season 1 is two seasons back")
		end,
	},
	{
		name = "tick reads the key and writes only when it is missing",
		run = function()
			local w = build()
			w.clock.t = 1050
			assert(w.tally:tick() == 1)
			assert(w.ds.calls == 1, "the missing key is written once")
			assert(w.tally:tick() == 1 and w.tally:tick() == 1)
			assert(w.ds.calls == 1, `an existing key costs no write: {w.ds.calls}`)
			closeStored(w, 1, 1100)
			w.tally:tick()
			assert(w.ds.calls == 1 and w.tally.known[1].state == "closed", "and the read still sees a close")
		end,
	},
	{
		name = "a cancelled open, with the store answering nil, reads what the rival wrote",
		run = function()
			local w = build()
			w.ds.cancelReturnsNil = true
			w.ds:hookNext(function()
				w.records["season/1"] = Season.open(nil, 1, 1000, 1100)
				w.records["season/1"].closedBy = "rival"
			end)
			local opened = w.tally:ensureOpen(1)
			assert(opened ~= nil and opened.closedBy == "rival", "the stored value, read after the cancel")
			assert(w.tally.known[1] ~= nil and w.tally.known[1].closedBy == "rival")
		end,
	},
	{
		-- SeasonLengthSeconds changed on a live game renumbers the seasons: the id the clock now gives
		-- maps to a stored key made under the old length. Nothing may be scored into or paid from it.
		name = "a stored season whose window is not the config's is refused: logged once, not scored into, not remembered",
		run = function()
			local w = build()
			w.clock.t = 1150
			w.live[1] = newProfile()
			-- length 100 puts season 2 at [1100, 1200); the key says [1100, 1300), as a length of 200 made it
			w.records["season/2"] = Season.close(Season.open(nil, 2, 1100, 1300), 1300, {}, "X")
			assert(w.tally:tick() == 2)
			assert(w.tally.known[2] == nil, "a key from another window is not remembered")
			local text = ""
			for _, line in w.logs do
				if string.find(line, "does not match", 1, true) then
					text ..= line
				end
			end
			assert(text ~= "" and string.find(text, "season 2", 1, true), table.concat(w.logs, "; "))
			w.tally:tick()
			local n = 0
			for _, line in w.logs do
				if string.find(line, "does not match", 1, true) then
					n += 1
				end
			end
			assert(n == 1, `logged once per season, not on every tick: {n}`)
			local ok, why = w.tally:record(1, 10)
			assert(not ok and why == "season_mismatch", tostring(why))
			assert(w.live[1].seasons["2"] == nil, "nothing was scored")
			assert(
				w.records["season/2"].state == "closed" and w.records["season/2"].endsAt == 1300,
				"key untouched"
			)
			-- put right (the operator restores the old length's key): the season works again
			w.records["season/2"] = Season.open(nil, 2, 1100, 1200)
			w.tally:tick()
			assert(w.tally:record(1, 10), "a key that matches again is used")
			assert(w.tally.known[2] ~= nil and w.live[1].seasons["2"].score == 10)
		end,
	},
	{
		name = "record never yields",
		run = function()
			local w = build()
			w.live[1] = newProfile()
			w.tally:tick()
			local finished = false
			local result: any = nil
			local run = coroutine.wrap(function()
				result = w.tally:record(1, 10)
				finished = true
			end)
			run()
			assert(finished and result == true, "it ran to the end without yielding")
			local thread = coroutine.create(function()
				w.tally:record(1, 10)
			end)
			coroutine.resume(thread)
			assert(coroutine.status(thread) == "dead")
		end,
	},
}
