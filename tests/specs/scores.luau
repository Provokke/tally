--!strict
local Deep = require("../fakes/Deep")
local Scores = require("../../src/server/Scores")

local SUM = { mode = "sum", maxPoints = 1000, stat = "points" }
local BEST = { mode = "best", maxPoints = 1000, stat = "points" }
local OPEN = { endsAt = 2000, state = "open" }

local function profile(): any
	return {
		coins = 0,
		lifetime = {},
		seasons = {},
		streak = { day = 0, count = 0, earned = 0 },
		notices = {},
	}
end

local function refused(p: any, points: any, season: any, now: number, rules: any, want: string)
	local before = Deep.copy(p)
	local ok, reason = Scores.record(p, 3, points, season, now, rules)
	assert(ok == false and reason == want, `expected {want}, got {tostring(reason)}`)
	assert(Deep.equal(p, before), `a {want} refusal must leave the profile untouched`)
end

return {
	{
		name = "sum adds each submission to the season score and to the lifetime total",
		run = function()
			local p = profile()
			assert(Scores.record(p, 3, 5, OPEN, 1500, SUM) == true)
			assert(Scores.record(p, 3, 7, OPEN, 1501, SUM) == true)
			assert(p.seasons["3"].score == 12 and p.seasons["3"].rewarded == false)
			assert(p.lifetime.points == 12)
			assert(Scores.score(p, 3) == 12 and Scores.score(p, 4) == 0)
		end,
	},
	{
		name = "best keeps the highest single submission but the lifetime total counts every point",
		run = function()
			local p = profile()
			for _, points in { 5, 3, 9, 4 } do
				assert(Scores.record(p, 3, points, OPEN, 1500, BEST) == true)
			end
			assert(p.seasons["3"].score == 9)
			assert(p.lifetime.points == 21)
		end,
	},
	{
		name = "season ids are string keys, so a profile can be stored",
		run = function()
			local p = profile()
			Scores.record(p, 3, 5, OPEN, 1500, SUM)
			assert(p.seasons[3] == nil and p.seasons["3"] ~= nil)
		end,
	},
	{
		name = "bad points are refused: zero, negative, fractional, text, NaN, infinite, nil and over the cap",
		run = function()
			local p = profile()
			for _, bad in { 0, -1, 1.5, "5", 0 / 0, math.huge, -math.huge, 1001 } do
				refused(p, bad, OPEN, 1500, SUM, "bad_points")
			end
			refused(p, nil, OPEN, 1500, SUM, "bad_points")
			assert(Scores.record(p, 3, 1000, OPEN, 1500, SUM) == true, "the cap itself is allowed")
		end,
	},
	{
		name = "a submission is refused once this server's clock reaches the end, and allowed a second before",
		run = function()
			local p = profile()
			assert(Scores.record(p, 3, 5, OPEN, 1999, SUM) == true)
			refused(p, 5, OPEN, 2000, SUM, "season_ended")
			refused(p, 5, OPEN, 9999, SUM, "season_ended")
		end,
	},
	{
		name = "a submission is refused once the player has been paid for the season, even when the clock is behind",
		run = function()
			local p = profile()
			p.seasons["3"] = { score = 40, rewarded = true, tier = "Bronze", reward = 50 }
			refused(p, 5, OPEN, 1000, SUM, "already_rewarded")
			assert(p.seasons["3"].score == 40)
		end,
	},
	{
		name = "a submission is refused once this server has seen the stored close",
		run = function()
			local p = profile()
			refused(p, 5, { endsAt = 2000, state = "closed" }, 1000, SUM, "closed")
		end,
	},
	{
		name = "refusals are checked in order: points, then the end, then paid, then closed",
		run = function()
			local p = profile()
			p.seasons["3"] = { score = 40, rewarded = true }
			refused(p, 0, { endsAt = 100, state = "closed" }, 5000, SUM, "bad_points")
			refused(p, 5, { endsAt = 100, state = "closed" }, 5000, SUM, "season_ended")
			refused(p, 5, { endsAt = 5000, state = "closed" }, 1000, SUM, "already_rewarded")
		end,
	},
	{
		name = "recording to one season leaves every other season and every other lifetime stat alone",
		run = function()
			local p = profile()
			p.seasons["2"] = { score = 80, rewarded = true, tier = "Silver", reward = 150 }
			p.lifetime.fish = 9
			local others = Deep.copy({ p.seasons["2"], p.lifetime.fish })
			Scores.record(p, 3, 5, OPEN, 1500, SUM)
			assert(Deep.equal({ p.seasons["2"], p.lifetime.fish }, others))
		end,
	},
	{
		name = "fuzz: in sum mode the lifetime total always equals the season scores, and a paid season never changes",
		run = function()
			local state = 11
			local function rand(n: number): number
				state = (state * 48271) % 2147483647
				return state % n + 1
			end
			for _ = 1, 500 do
				local p = profile()
				local frozen: any = nil
				for step = 1, 12 do
					local seasonId = rand(3)
					local points: any = if rand(8) == 1 then -rand(5) else rand(40)
					local now = 1900 + rand(200)
					local view = { endsAt = 2000, state = if rand(6) == 1 then "closed" else "open" }
					Scores.record(p, seasonId, points, view, now, SUM)
					if step == 6 and p.seasons["1"] ~= nil then
						p.seasons["1"].rewarded = true
						frozen = Deep.copy(p.seasons["1"])
					end
					local total = 0
					for _, entry in p.seasons do
						total += entry.score
					end
					assert((p.lifetime.points or 0) == total, "lifetime must equal the sum of season scores")
					if frozen ~= nil then
						assert(Deep.equal(p.seasons["1"], frozen), "a paid season must never change")
					end
				end
			end
		end,
	},
}
