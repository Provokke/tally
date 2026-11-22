--!strict
local Conservation = require("../fakes/Conservation")
local Deep = require("../fakes/Deep")

local OPTS = { currentId = 3, mode = "sum" }

-- Player 1 scored 60 in season 1 and was paid Silver (150) plus first place (300) on top of a
-- start of 100 Coins, with a streak that earned 25. Season 1 is closed.
local function world(): { [string]: any }
	return {
		["profile/1"] = {
			coins = 100 + 450 + 25,
			lifetime = { points = 60 },
			seasons = { ["1"] = { score = 60, rewarded = true, tier = "Silver", reward = 450 } },
			streak = { day = 5, count = 2, earned = 25 },
			notices = {},
		},
		["season/1"] = {
			id = 1,
			startsAt = 1000,
			endsAt = 1100,
			state = "closed",
			podium = { { userId = 1, score = 60 } },
			closedBy = "A",
			closedAt = 1100,
		},
	}
end

local START = { [1] = 100 }

local function expectFail(records: any, needle: string, start: any?, opts: any?)
	local ok, reason = Conservation.check(records, start or START, opts or OPTS)
	assert(not ok, "expected the check to fail")
	assert(reason ~= nil and string.find(reason, needle, 1, true), `reason {reason} lacks {needle}`)
end

return {
	{
		name = "a settled world passes",
		run = function()
			local ok, reason = Conservation.check(world(), START, OPTS)
			assert(ok, reason)
			assert(reason == nil)
		end,
	},
	{
		name = "a double payout fails and names the player",
		run = function()
			local records = world()
			records["profile/1"].coins += 450
			expectFail(records, "player 1")
		end,
	},
	{
		name = "a missing payout fails",
		run = function()
			local records = world()
			records["profile/1"].coins -= 450
			expectFail(records, "player 1")
		end,
	},
	{
		name = "a season paid without a reward fails, naming player and season",
		run = function()
			local records = world()
			records["profile/1"].seasons["1"].reward = nil
			expectFail(records, "player 1 season 1")
		end,
	},
	{
		name = "a reward without the paid flag fails, naming player and season",
		run = function()
			local records = world()
			records["profile/1"].seasons["1"].rewarded = false
			expectFail(records, "player 1 season 1")
		end,
	},
	{
		name = "a lifetime that differs from the season sum fails in sum mode",
		run = function()
			local records = world()
			records["profile/1"].lifetime.points = 61
			expectFail(records, "lifetime")
			records["profile/1"].lifetime.points = nil
			expectFail(records, "lifetime")
		end,
	},
	{
		name = "best mode skips the lifetime check",
		run = function()
			local records = world()
			records["profile/1"].lifetime.points = 99
			local ok, reason = Conservation.check(records, START, { currentId = 3, mode = "best" })
			assert(ok, reason)
		end,
	},
	{
		name = "an old scored season that is not rewarded fails",
		run = function()
			local records = world()
			local profile = records["profile/1"]
			profile.seasons["2"] = { score = 10, rewarded = false }
			profile.lifetime.points = 70
			expectFail(records, "season 2")
			-- control: the current season is not old
			profile.seasons["2"] = nil
			profile.seasons["3"] = { score = 10, rewarded = false }
			local ok, reason = Conservation.check(records, START, OPTS)
			assert(ok, reason)
		end,
	},
	{
		name = "an old scored season whose key is missing or still open fails",
		run = function()
			local records = world()
			records["season/1"] = nil
			expectFail(records, "season 1")
			local open = world()
			open["season/1"].state = "open"
			expectFail(open, "season 1")
		end,
	},
	{
		name = "settled = false skips only the unsettled check",
		run = function()
			local opts = { currentId = 3, mode = "sum", settled = false }
			local records = world()
			local profile = records["profile/1"]
			profile.seasons["2"] = { score = 10, rewarded = false }
			profile.lifetime.points = 70
			local ok, reason = Conservation.check(records, START, opts)
			assert(ok, reason)
			-- the coin check still runs
			profile.coins += 1
			expectFail(records, "player 1", START, opts)
			profile.coins -= 1
			-- and so does the closed check on a rewarded season
			records["season/1"].state = "open"
			expectFail(records, "season 1", START, opts)
		end,
	},
	{
		name = "a rewarded season whose stored key is open or missing fails",
		run = function()
			local records = world()
			records["season/1"].state = "open"
			expectFail(records, "season 1")
			records["season/1"] = nil
			expectFail(records, "season 1")
		end,
	},
	{
		name = "a user with no stored profile counts as their start Coins",
		run = function()
			local records = world()
			local start = { [1] = 100, [2] = 70 }
			local ok, reason = Conservation.check(records, start, OPTS)
			assert(ok, reason)
			-- control: a stored profile one Coin short fails
			records["profile/2"] = {
				coins = 69,
				lifetime = {},
				seasons = {},
				streak = { day = 0, count = 0, earned = 0 },
				notices = {},
			}
			expectFail(records, "player 2", start)
		end,
	},
	{
		name = "streak earnings are counted and the check never changes its input",
		run = function()
			local records = world()
			local before = Deep.copy(records)
			records["profile/1"].streak.earned = 0
			expectFail(records, "player 1")
			records["profile/1"].streak.earned = 25
			assert(Deep.equal(records, before))
		end,
	},
}
