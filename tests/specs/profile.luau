--!strict
local Deep = require("../fakes/Deep")
local Profile = require("../../src/server/Data/Profile")

local function fullProfile(): any
	return {
		coins = 40,
		lifetime = { points = 12 },
		seasons = { ["3"] = { score = 12, rewarded = false } },
		streak = { day = 20000, count = 3, earned = 45 },
		notices = { { text = "hello", at = 5 } },
	}
end

return {
	{
		name = "a new profile has the starting coins and empty tables",
		run = function()
			local profile = Profile.new({ startingCoins = 25 })
			local data = profile.defaultData()
			assert(
				Deep.equal(data, {
					coins = 25,
					lifetime = {},
					seasons = {},
					streak = { day = 0, count = 0, earned = 0 },
					notices = {},
				}),
				"default shape"
			)
			local other = profile.defaultData()
			other.seasons["1"] = {}
			assert(next(profile.defaultData().seasons) == nil, "each call returns fresh tables")
		end,
	},
	{
		name = "decode raises for nil, a string and a table with no coins",
		run = function()
			local profile = Profile.new({ startingCoins = 0 })
			assert(not pcall(profile.decode, nil :: any))
			assert(not pcall(profile.decode, "text" :: any))
			assert(not pcall(profile.decode, { lifetime = {} }))
			assert(not pcall(profile.decode, { coins = "5" }))
			assert(pcall(profile.decode, { coins = 0 }), "control: a coins number decodes")
		end,
	},
	{
		name = "decode fills each missing table",
		run = function()
			local profile = Profile.new({ startingCoins = 0 })
			local data = profile.decode({ coins = 9 })
			assert(Deep.equal(data.lifetime, {}) and Deep.equal(data.seasons, {}))
			assert(Deep.equal(data.notices, {}))
			assert(Deep.equal(data.streak, { day = 0, count = 0, earned = 0 }))
			local wrong = profile.decode({ coins = 9, lifetime = 1, seasons = "x", notices = true })
			assert(
				Deep.equal(wrong.lifetime, {})
					and Deep.equal(wrong.seasons, {})
					and Deep.equal(wrong.notices, {})
			)
		end,
	},
	{
		name = "a malformed streak becomes the default and a good one is kept",
		run = function()
			local profile = Profile.new({ startingCoins = 0 })
			local fresh = { day = 0, count = 0, earned = 0 }
			assert(Deep.equal(profile.decode({ coins = 1, streak = 7 }).streak, fresh))
			assert(Deep.equal(profile.decode({ coins = 1, streak = { day = 1, count = 2 } }).streak, fresh))
			assert(
				Deep.equal(
					profile.decode({ coins = 1, streak = { day = "1", count = 2, earned = 3 } }).streak,
					fresh
				)
			)
			local kept = profile.decode({ coins = 1, streak = { day = 1, count = 2, earned = 3 } }).streak
			assert(Deep.equal(kept, { day = 1, count = 2, earned = 3 }))
		end,
	},
	{
		name = "encode then decode round-trips a full profile",
		run = function()
			local profile = Profile.new({ startingCoins = 0 })
			local original = fullProfile()
			local back = profile.decode(profile.encode(original))
			assert(Deep.equal(back, fullProfile()), "round trip")
			assert(Deep.equal(original, fullProfile()), "the original is untouched")
		end,
	},
	{
		name = "encode returns a copy",
		run = function()
			local profile = Profile.new({ startingCoins = 0 })
			local original = fullProfile()
			local copy = profile.encode(original)
			copy.coins = 999
			copy.seasons["3"].score = 999
			copy.notices[1].text = "changed"
			assert(
				original.coins == 40
					and original.seasons["3"].score == 12
					and original.notices[1].text == "hello"
			)
		end,
	},
	{
		name = "decode does not change a profile that has a season key '3'",
		run = function()
			local profile = Profile.new({ startingCoins = 0 })
			local data = profile.decode(fullProfile())
			assert(data.seasons["3"] ~= nil and data.seasons["3"].score == 12)
			assert(data.seasons[3] == nil, "the key stays a string")
			local count = 0
			for _ in data.seasons do
				count += 1
			end
			assert(count == 1)
		end,
	},
}
