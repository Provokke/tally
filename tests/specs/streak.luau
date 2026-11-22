--!strict
local Deep = require("../fakes/Deep")
local Streak = require("../../src/server/Streak")

local REWARDS = { 10, 15, 20 }
local D = 20000

return {
	{
		name = "dayOf is the UTC day number",
		run = function()
			assert(Streak.dayOf(0) == 0 and Streak.dayOf(86399) == 0 and Streak.dayOf(86400) == 1)
			assert(Streak.dayOf(86400 * 20000 + 5) == 20000)
		end,
	},
	{
		name = "a first claim starts the streak at 1 and pays the first reward",
		run = function()
			local claimed = Streak.claim(nil, D, REWARDS) :: any
			assert(claimed.reward == 10)
			assert(claimed.streak.day == D and claimed.streak.count == 1 and claimed.streak.earned == 10)
		end,
	},
	{
		name = "a second claim the same day is refused, and so is a claim from a clock that is a day behind",
		run = function()
			local first = Streak.claim(nil, D, REWARDS) :: any
			local same, why = Streak.claim(first.streak, D, REWARDS)
			assert(same == nil and why == "already_claimed")
			local behind, behindWhy = Streak.claim(first.streak, D - 1, REWARDS)
			assert(behind == nil and behindWhy == "already_claimed")
		end,
	},
	{
		name = "the next day continues the streak and pays the next reward",
		run = function()
			local a = Streak.claim(nil, D, REWARDS) :: any
			local b = Streak.claim(a.streak, D + 1, REWARDS) :: any
			assert(b.reward == 15 and b.streak.count == 2 and b.streak.earned == 25)
		end,
	},
	{
		name = "a missed day restarts at 1 but keeps the Coins earned so far",
		run = function()
			local a = Streak.claim(nil, D, REWARDS) :: any
			local b = Streak.claim(a.streak, D + 1, REWARDS) :: any
			local c = Streak.claim(b.streak, D + 3, REWARDS) :: any
			assert(c.reward == 10 and c.streak.count == 1 and c.streak.earned == 35)
		end,
	},
	{
		name = "the reward is capped at the last entry",
		run = function()
			local s: any = nil
			local reward = 0
			for i = 0, 5 do
				local claimed = Streak.claim(s, D + i, REWARDS) :: any
				s, reward = claimed.streak, claimed.reward
			end
			assert(s.count == 6 and reward == 20)
		end,
	},
	{
		name = "claim refuses a bad day and an empty reward list, and never mutates its input",
		run = function()
			for _, bad in { 0, -3, 1.5, 0 / 0 } do
				local out, why = Streak.claim(nil, bad, REWARDS)
				assert(out == nil and why == "bad_day")
			end
			local none, noneWhy = Streak.claim(nil, D, {})
			assert(none == nil and noneWhy == "no_rewards")
			local s = { day = D, count = 2, earned = 25 }
			local before = Deep.copy(s)
			Streak.claim(s, D + 1, REWARDS)
			assert(Deep.equal(s, before))
		end,
	},
	{
		name = "state shows what a player can do today",
		run = function()
			local fresh = Streak.state(nil, D, REWARDS)
			assert(fresh.canClaim and not fresh.broken and fresh.count == 0 and fresh.nextReward == 10)
			local a = (Streak.claim(nil, D, REWARDS) :: any).streak
			local claimed = Streak.state(a, D, REWARDS)
			assert(
				not claimed.canClaim
					and not claimed.broken
					and claimed.count == 1
					and claimed.nextReward == 15
			)
			local tomorrow = Streak.state(a, D + 1, REWARDS)
			assert(
				tomorrow.canClaim
					and not tomorrow.broken
					and tomorrow.count == 1
					and tomorrow.nextReward == 15
			)
			local missed = Streak.state(a, D + 2, REWARDS)
			assert(missed.canClaim and missed.broken and missed.count == 0 and missed.nextReward == 10)
		end,
	},
}
