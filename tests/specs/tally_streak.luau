--!strict
-- Tally.claimStreak over a stub profiles table whose save counts calls (and can fail or park), the
-- real pure modules, and a FakeClock set per case. UTC day 20000 starts at 20000 * 86400.
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

local DAY = 86400
local DAY_20000 = 20000 * DAY

local function newProfile(streak: any?): any
	return {
		coins = 0,
		lifetime = {},
		seasons = {},
		streak = streak or { day = 0, count = 0, earned = 0 },
		notices = {},
	}
end

local function build(): any
	local w: any = {}
	w.clock = FakeClock.new(DAY_20000 + 100)
	w.records = {}
	w.ds = FakeDataStore.new(w.records)
	w.handle = w.ds:handle(Faults.new())
	w.ordered = FakeOrderedDataStore.new(w.clock, 0)
	local orderedHandle = w.ordered:handle(Faults.new())
	local board: any = {
		SetAsync = function(_: any, key: string, value: number)
			orderedHandle:SetAsync(key, value)
		end,
		GetSortedAsync = function(_: any, ...: any)
			return orderedHandle:GetSortedAsync(...)
		end,
	}
	w.logs = {}
	local function log(message: string)
		table.insert(w.logs, message)
	end
	w.live = {} :: { [number]: any }
	w.saves = 0
	w.failSave = false
	w.config = Deep.copy(Config)
	w.config.Epoch = 1000
	w.tally = Tally.new({
		seasons = w.handle,
		leaderboard = Leaderboard.new({
			store = function(_: number): any
				return board
			end,
			now = function(): number
				return w.clock:now()
			end,
			size = 10,
			refreshSeconds = 15,
			log = log,
		}),
		profiles = {
			get = function(userId: number): any
				if w.getThrows then
					error("profiles broke")
				end
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
		serverId = "A",
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

local function world(streak: any?): any
	local w = build()
	w.live[1] = newProfile(streak)
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

-- Runs fn in its own thread, so a parked save leaves it suspended for the spec to resume.
local function async(fn: () -> ...any): any
	local run: any = { done = false }
	run.co = coroutine.create(function()
		run.results = table.pack(fn())
		run.done = true
	end)
	local ok, err = coroutine.resume(run.co)
	assert(ok, err)
	return run
end

local function resume(run: any)
	local ok, err = coroutine.resume(run.co)
	assert(ok, err)
end

local function claim(w: any): (boolean, string?, number?)
	return w.tally:claimStreak(1)
end

return {
	{
		name = "a first claim pays the first reward, sets the streak, adds one notice and makes one save",
		run = function()
			local w = world()
			local ok, why, reward = claim(w)
			assert(
				ok == true and why == nil and reward == 10,
				`{tostring(ok)} {tostring(why)} {tostring(reward)}`
			)
			local profile = w.live[1]
			assert(Deep.equal(profile.streak, { day = 20000, count = 1, earned = 10 }))
			assert(profile.coins == 10)
			assert(#profile.notices == 1 and profile.notices[1].text == "Streak day 1: 10 Coins claimed.")
			assert(w.saves == 1, `{w.saves} saves`)
			assert(not w.tally:busy(1), "the guard is released")
		end,
	},
	{
		name = "a second claim the same UTC day is refused, with no save, no Coins and no notice",
		run = function()
			local w = world()
			assert(claim(w))
			w.clock.t = DAY_20000 + DAY - 1
			local ok, why, reward = claim(w)
			assert(ok == false and why == "already_claimed" and reward == nil, tostring(why))
			assert(w.saves == 1 and w.live[1].coins == 10 and #w.live[1].notices == 1)
		end,
	},
	{
		name = "the next day continues, a missed day restarts with earned kept, and the reward caps at the last entry",
		run = function()
			local w = world()
			assert(claim(w))
			w.clock.t = DAY_20000 + DAY + 5
			local ok, _, reward = claim(w)
			assert(ok and reward == 15 and w.live[1].streak.count == 2, tostring(reward))
			assert(w.live[1].coins == 25 and w.saves == 2)
			-- A missed day: day 20003 after day 20001.
			w.clock.t = DAY_20000 + 3 * DAY
			ok, _, reward = claim(w)
			assert(ok and reward == 10, tostring(reward))
			assert(Deep.equal(w.live[1].streak, { day = 20003, count = 1, earned = 35 }))
			-- The cap: the seventh day and later pay 100.
			local rewards = {}
			local capped = world({ day = 19999, count = 5, earned = 0 })
			for i = 0, 3 do
				capped.clock.t = DAY_20000 + i * DAY
				local _, _, got = capped.tally:claimStreak(1)
				table.insert(rewards, got)
			end
			assert(Deep.equal(rewards, { 60, 100, 100, 100 }), table.concat(rewards, ","))
			assert(capped.live[1].streak.count == 9)
		end,
	},
	{
		name = "a server whose clock is a day behind is refused as already claimed",
		run = function()
			local w = world({ day = 20001, count = 3, earned = 40 })
			local before = Deep.copy(w.live[1])
			local ok, why = claim(w)
			assert(ok == false and why == "already_claimed")
			assert(Deep.equal(w.live[1], before) and w.saves == 0)
		end,
	},
	{
		name = "the day boundary: one second before 20000 * 86400 is day 19999, and the boundary is day 20000",
		run = function()
			local w = world()
			w.clock.t = DAY_20000 - 1
			assert(claim(w))
			assert(w.live[1].streak.day == 19999, `{w.live[1].streak.day}`)
			w.clock.t = DAY_20000
			local ok, _, reward = claim(w)
			assert(ok and reward == 15 and w.live[1].streak.day == 20000 and w.live[1].streak.count == 2)
		end,
	},
	{
		name = "a failed save leaves the profile exactly as it was, and the next claim pays once",
		run = function()
			local w = world()
			local before = Deep.copy(w.live[1])
			w.failSave = true
			local ok, why, reward = claim(w)
			assert(ok == false and why == "save_failed" and reward == nil, tostring(why))
			assert(Deep.equal(w.live[1], before), "streak, Coins and notices are as before")
			assert(logged(w, "streak save failed for 1") == 1 and w.saves == 1)
			w.failSave = false
			local paid, _, got = claim(w)
			assert(paid and got == 10 and w.live[1].coins == 10 and #w.live[1].notices == 1)
			assert(not (claim(w)) and w.live[1].coins == 10)
			assert(w.saves == 2, `{w.saves} saves`)
		end,
	},
	{
		name = "a failed save rolls back relative to now: Coins and notices changed while it was parked are kept",
		run = function()
			local w = world()
			w.parkSave = true
			local run = async(function()
				return claim(w)
			end)
			assert(
				not run.done and w.live[1].coins == 10 and w.live[1].streak.count == 1,
				"parked in the save"
			)
			w.live[1].coins += 5
			table.insert(w.live[1].notices, { text = "Another notice.", at = 1 })
			w.failSave = true
			resume(run)
			assert(run.results[1] == false and run.results[2] == "save_failed")
			local profile = w.live[1]
			assert(profile.coins == 5, `only the claim is undone, the 5 kept: {profile.coins}`)
			assert(#profile.notices == 1 and profile.notices[1].text == "Another notice.")
			assert(Deep.equal(profile.streak, { day = 0, count = 0, earned = 0 }))
			w.failSave = false
			assert(claim(w))
			assert(profile.coins == 15 and #profile.notices == 2)
		end,
	},
	{
		name = "a failed save puts back only the streak fields this claim changed, keeping one changed meanwhile",
		run = function()
			-- A claim after a missed day leaves count at 1, so it did not change count.
			local w = world({ day = 19990, count = 1, earned = 10 })
			w.parkSave = true
			local run = async(function()
				return claim(w)
			end)
			assert(Deep.equal(w.live[1].streak, { day = 20000, count = 1, earned = 20 }))
			w.live[1].streak.count = 7 -- changed by something else while the save was in flight
			w.failSave = true
			resume(run)
			assert(run.results[2] == "save_failed")
			assert(
				Deep.equal(w.live[1].streak, { day = 19990, count = 7, earned = 10 }),
				`{w.live[1].streak.day} {w.live[1].streak.count} {w.live[1].streak.earned}`
			)
		end,
	},
	{
		name = "no live profile is no_profile, with no save",
		run = function()
			local w = build()
			local ok, why, reward = claim(w)
			assert(ok == false and why == "no_profile" and reward == nil)
			assert(w.saves == 0 and not w.tally:busy(1))
		end,
	},
	{
		name = "a claim that raises is logged and answers error, and the guard is released",
		run = function()
			local w = world()
			w.getThrows = true
			local ok, why = claim(w)
			assert(ok == false and why == "error" and logged(w, "streak claim failed for 1") == 1)
			assert(not w.tally:busy(1))
			w.getThrows = false
			assert(claim(w))
		end,
	},
	{
		name = "a second claim while the first is parked in its save is busy, and the Coins are paid once",
		run = function()
			local w = world()
			w.parkSave = true
			local run = async(function()
				return claim(w)
			end)
			assert(w.tally:busy(1))
			local ok, why, reward = claim(w)
			assert(ok == false and why == "busy" and reward == nil)
			assert(w.live[1].coins == 10 and w.saves == 1)
			resume(run)
			assert(run.results[1] == true and run.results[3] == 10)
			assert(w.live[1].coins == 10 and #w.live[1].notices == 1 and w.saves == 1)
			assert(not w.tally:busy(1))
		end,
	},
	{
		name = "fifty claims across one UTC day pay once, refuse 49 and make one save",
		run = function()
			local w = world()
			local paid, refused = 0, 0
			for i = 1, 50 do
				w.clock.t = DAY_20000 + i * 1000
				local ok, why = claim(w)
				if ok then
					paid += 1
				else
					assert(why == "already_claimed", tostring(why))
					refused += 1
				end
			end
			assert(paid == 1 and refused == 49 and w.saves == 1 and w.live[1].coins == 10)
		end,
	},
	{
		name = "a claim and a settle for one player at once both complete, and the profile has both changes",
		run = function()
			local w = world()
			w.live[1].seasons["1"] = { score = 60, rewarded = false }
			local at = w.clock.t
			w.clock.t = 0
			w.ordered:write("1", 60)
			w.clock.t = at
			w.parkSave = true
			local settling = async(function()
				return w.tally:settle(1)
			end)
			assert(not settling.done and w.live[1].coins == 450, "the settle is parked in its payout save")
			assert(w.tally:busy(1))
			local ok, _, reward = claim(w)
			assert(ok == true and reward == 10, "the claim ran while the settle was parked")
			resume(settling)
			assert(settling.results[1] == 1, `paid {tostring(settling.results[1])}`)
			local profile = w.live[1]
			assert(profile.coins == 460, `coins {profile.coins}`)
			assert(profile.seasons["1"].rewarded == true and profile.streak.count == 1)
			assert(#profile.notices == 2 and w.saves == 2)
		end,
	},
}
