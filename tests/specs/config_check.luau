--!strict
local Config = require("../../src/shared/Config")
local ConfigCheck = require("../../src/shared/ConfigCheck")
local Deep = require("../fakes/Deep")

-- Breaks a deep copy of the shipped config with `change`, and checks the check fails with a
-- reason that names `needle`. The unbroken copy must pass first, so a failure is the change's.
local function flagged(change: (config: any) -> (), needle: string)
	local config = Deep.copy(Config)
	assert(ConfigCheck.check(config), "control: the shipped config is clean")
	change(config)
	local ok, reason = ConfigCheck.check(config)
	assert(ok == false, `expected a failure naming "{needle}"`)
	assert(
		reason ~= nil and string.find(reason, needle, 1, true),
		`expected "{needle}", got: {tostring(reason)}`
	)
end

local NUMBERS = {
	"SchemaVersion",
	"AutosaveSeconds",
	"LeaseSeconds",
	"LoadRetries",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"Epoch",
	"SeasonLengthSeconds",
	"DemoSeasonSeconds",
	"StartingCoins",
	"MaxPointsPerCall",
	"PodiumSize",
	"SettleSeconds",
	"CloseGraceSeconds",
	"PodiumWaitSeconds",
	"PodiumMaxSeconds",
	"SeasonTickSeconds",
	"BoardPushSeconds",
	"BoardRefreshSeconds",
	"BoardCacheSize",
	"BoardPageSize",
	"NoticeCap",
}

local STRINGS = { "DataStoreName", "SeasonStoreName", "BoardStorePrefix", "ScoreStat" }

local FLOORS: { { any } } = {
	{ "SchemaVersion", 1 },
	{ "LoadRetries", 1 },
	{ "MaxPointsPerCall", 1 },
	{ "PodiumSize", 1 },
	{ "BoardPageSize", 1 },
	{ "NoticeCap", 1 },
	{ "StartingCoins", 0 },
	{ "Epoch", 0 },
}

local ABOVE_ZERO = {
	"AutosaveSeconds",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"SeasonLengthSeconds",
	"DemoSeasonSeconds",
	"SettleSeconds",
	"CloseGraceSeconds",
	"PodiumWaitSeconds",
	"PodiumMaxSeconds",
	"SeasonTickSeconds",
	"BoardPushSeconds",
	"BoardRefreshSeconds",
}

return {
	{
		name = "the shipped config passes",
		run = function()
			local ok, reason = ConfigCheck.check(Config)
			assert(ok, tostring(reason))
			assert(reason == nil, "no reason on success")
		end,
	},
	{
		name = "a missing or non-number field is flagged",
		run = function()
			for _, field in NUMBERS do
				flagged(function(c)
					c[field] = nil
				end, field)
				flagged(function(c)
					c[field] = "5"
				end, field)
			end
			flagged(function(c)
				c.StartingCoins = 0 / 0
			end, "StartingCoins")
			flagged(function(c)
				c.Epoch = math.huge
			end, "Epoch")
		end,
	},
	{
		name = "an empty, missing or over-long name is flagged",
		run = function()
			for _, field in STRINGS do
				flagged(function(c)
					c[field] = ""
				end, field)
				flagged(function(c)
					c[field] = nil
				end, field)
				flagged(function(c)
					c[field] = 7
				end, field)
				flagged(function(c)
					c[field] = string.rep("x", 33)
				end, field)
			end
		end,
	},
	{
		name = "a whole number below its floor, or a fraction, is flagged",
		run = function()
			for _, entry in FLOORS do
				local field, floor = entry[1], entry[2]
				flagged(function(c)
					c[field] = floor - 1
				end, field)
				flagged(function(c)
					c[field] = floor + 0.5
				end, field)
			end
		end,
	},
	{
		name = "a duration of zero or less is flagged",
		run = function()
			for _, field in ABOVE_ZERO do
				flagged(function(c)
					c[field] = 0
				end, field)
				flagged(function(c)
					c[field] = -1
				end, field)
			end
		end,
	},
	{
		name = "BoardCacheSize must be whole, 1 to 100, and cover a page and the podium",
		run = function()
			flagged(function(c)
				c.BoardCacheSize = 0
			end, "BoardCacheSize")
			flagged(function(c)
				c.BoardCacheSize = 101
			end, "BoardCacheSize")
			flagged(function(c)
				c.BoardCacheSize = 20.5
			end, "BoardCacheSize")
			flagged(function(c)
				c.BoardCacheSize = c.BoardPageSize - 1
			end, "BoardCacheSize")
			flagged(function(c)
				c.PodiumSize = 3
				c.PodiumBonus = { 3, 2, 1 }
				c.BoardPageSize = 1
				c.BoardCacheSize = 2
			end, "BoardCacheSize")
			local config = Deep.copy(Config)
			config.BoardCacheSize = 100
			assert(ConfigCheck.check(config), "100 is allowed")
			config.BoardCacheSize = config.BoardPageSize
			assert(ConfigCheck.check(config), "equal to a page is allowed")
		end,
	},
	{
		name = "ScoreMode must be sum or best",
		run = function()
			flagged(function(c)
				c.ScoreMode = "total"
			end, "ScoreMode")
			flagged(function(c)
				c.ScoreMode = nil
			end, "ScoreMode")
			local config = Deep.copy(Config)
			config.ScoreMode = "best"
			assert(ConfigCheck.check(config), "best is allowed")
		end,
	},
	{
		name = "PodiumBonus must hold PodiumSize whole numbers of 0 or more",
		run = function()
			flagged(function(c)
				c.PodiumBonus = { 300, 200 }
			end, "PodiumBonus")
			flagged(function(c)
				c.PodiumBonus = { 300, 200, 100, 50 }
			end, "PodiumBonus")
			flagged(function(c)
				c.PodiumBonus = { 300, -1, 100 }
			end, "PodiumBonus")
			flagged(function(c)
				c.PodiumBonus = { 300, 1.5, 100 }
			end, "PodiumBonus")
			flagged(function(c)
				c.PodiumBonus = { 300, "200", 100 }
			end, "PodiumBonus")
			flagged(function(c)
				c.PodiumBonus = nil
			end, "PodiumBonus")
			flagged(function(c)
				c.PodiumBonus = 5
			end, "PodiumBonus")
			local config = Deep.copy(Config)
			config.PodiumBonus = { 0, 0, 0 }
			assert(ConfigCheck.check(config), "zeros are allowed")
		end,
	},
	{
		name = "PodiumBonus one short of PodiumSize fails",
		run = function()
			flagged(function(c)
				local short = {}
				for i = 1, c.PodiumSize - 1 do
					short[i] = c.PodiumBonus[i]
				end
				c.PodiumBonus = short
			end, "PodiumBonus")
		end,
	},
	{
		name = "Tiers must be a strictly ascending list of named, whole tiers",
		run = function()
			flagged(function(c)
				c.Tiers = {}
			end, "Tiers")
			flagged(function(c)
				c.Tiers = nil
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].name = ""
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].name = 5
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].min = 0
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].min = 2.5
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].min = nil
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].coins = -1
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1].coins = 1.5
			end, "Tiers")
			flagged(function(c)
				c.Tiers[2].name = c.Tiers[1].name
			end, "Tiers")
			flagged(function(c)
				c.Tiers[1] = 5
			end, "Tiers")
			local config = Deep.copy(Config)
			config.Tiers[1].coins = 0
			assert(ConfigCheck.check(config), "a tier worth 0 Coins is allowed")
		end,
	},
	{
		name = "Tiers with equal min values, and in descending order, both fail",
		run = function()
			flagged(function(c)
				c.Tiers[2].min = c.Tiers[1].min
			end, "Tiers")
			flagged(function(c)
				c.Tiers = { c.Tiers[3], c.Tiers[2], c.Tiers[1] }
			end, "Tiers")
		end,
	},
	{
		name = "StreakRewards must be a non-empty list of whole numbers of 0 or more",
		run = function()
			flagged(function(c)
				c.StreakRewards = {}
			end, "StreakRewards")
			flagged(function(c)
				c.StreakRewards = nil
			end, "StreakRewards")
			flagged(function(c)
				c.StreakRewards = { 10, -5 }
			end, "StreakRewards")
			flagged(function(c)
				c.StreakRewards = { 10, 2.5 }
			end, "StreakRewards")
			flagged(function(c)
				c.StreakRewards = { 10, "20" }
			end, "StreakRewards")
			local config = Deep.copy(Config)
			config.StreakRewards = { 0 }
			assert(ConfigCheck.check(config), "a single 0 is allowed")
		end,
	},
	{
		name = "LeaseSeconds must be above AutosaveSeconds",
		run = function()
			flagged(function(c)
				c.LeaseSeconds = c.AutosaveSeconds
			end, "LeaseSeconds")
			flagged(function(c)
				c.LeaseSeconds = c.AutosaveSeconds - 1
			end, "LeaseSeconds")
		end,
	},
	{
		name = "Limits is checked, and a missing limit returns false rather than throwing",
		run = function()
			flagged(function(c)
				c.Limits = nil
			end, "Limits")
			flagged(function(c)
				c.Limits = 5
			end, "Limits")
			flagged(function(c)
				c.Limits.BurstPerPlayer = nil
			end, "Limits.BurstPerPlayer")
			flagged(function(c)
				c.Limits.BurstPerPlayer = 0
			end, "Limits.BurstPerPlayer")
			flagged(function(c)
				c.Limits.RefillPerSecond = -1
			end, "Limits.RefillPerSecond")
			flagged(function(c)
				c.Limits.RefillPerSecond = "2"
			end, "Limits.RefillPerSecond")
		end,
	},
	{
		name = "the store limits must be whole numbers and the claim costed",
		run = function()
			for _, field in { "StoreBurstPerPlayer", "StoreOpsPerMinute" } do
				flagged(function(c)
					c.Limits[field] = 0
				end, field)
				flagged(function(c)
					c.Limits[field] = 2.5
				end, field)
				flagged(function(c)
					c.Limits[field] = nil
				end, field)
			end
			flagged(function(c)
				c.Limits.StoreCost = nil
			end, "StoreCost")
			flagged(function(c)
				c.Limits.StoreCost = 5
			end, "StoreCost")
			flagged(function(c)
				c.Limits.StoreCost.claim_streak = nil
			end, "StoreCost.claim_streak")
			flagged(function(c)
				c.Limits.StoreCost.claim_streak = 0
			end, "StoreCost.claim_streak")
			flagged(function(c)
				c.Limits.StoreCost.claim_streak = 1.5
			end, "StoreCost.claim_streak")
			flagged(function(c)
				c.Limits.StoreCost.claim_streak = c.Limits.StoreBurstPerPlayer + 1
			end, "StoreCost.claim_streak")
			local config = Deep.copy(Config)
			config.Limits.StoreCost.claim_streak = config.Limits.StoreBurstPerPlayer
			assert(ConfigCheck.check(config), "a cost equal to the burst is allowed")
		end,
	},
	{
		name = "a config that is not a table returns false rather than throwing",
		run = function()
			local ok, reason = ConfigCheck.check(nil)
			assert(ok == false and reason ~= nil)
			ok, reason = ConfigCheck.check(5)
			assert(ok == false and reason ~= nil)
			ok, reason = ConfigCheck.check({})
			assert(ok == false and reason ~= nil)
		end,
	},
}
