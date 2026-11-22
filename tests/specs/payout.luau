--!strict
local Deep = require("../fakes/Deep")
local Payout = require("../../src/server/Payout")

local RULES = {
	tiers = {
		{ name = "Bronze", min = 10, coins = 50 },
		{ name = "Silver", min = 50, coins = 150 },
		{ name = "Gold", min = 150, coins = 400 },
	},
	podiumBonus = { 300, 200, 100 },
}

local function closed(podium: any): any
	return { id = 5, endsAt = 1000, state = "closed", podium = podium }
end

local function openSeason(): any
	return { id = 5, endsAt = 1000, state = "open", podium = {} }
end

local function entry(score: number, rewarded: boolean?): any
	return { score = score, rewarded = rewarded == true }
end

local function lcg(seed: number): (number) -> number
	local state = seed
	return function(n: number): number
		state = (state * 48271) % 2147483647
		return state % n + 1
	end
end

return {
	{
		name = "tierFor is the highest threshold the score meets, whatever the list order",
		run = function()
			assert(Payout.tierFor(9, RULES.tiers) == nil)
			assert((Payout.tierFor(10, RULES.tiers) :: any).name == "Bronze")
			assert((Payout.tierFor(149, RULES.tiers) :: any).name == "Silver")
			assert((Payout.tierFor(150, RULES.tiers) :: any).name == "Gold")
			local shuffled = { RULES.tiers[3], RULES.tiers[1], RULES.tiers[2] }
			assert((Payout.tierFor(60, shuffled) :: any).name == "Silver")
		end,
	},
	{
		name = "placeOf is the podium place, and nil off the podium",
		run = function()
			local podium = { { userId = 7, score = 9 }, { userId = 4, score = 8 } }
			assert(Payout.placeOf(podium, 4) == 2 and Payout.placeOf(podium, 7) == 1)
			assert(Payout.placeOf(podium, 9) == nil)
		end,
	},
	{
		name = "reward is the tier Coins plus the podium bonus, and either alone is enough",
		run = function()
			local podium =
				{ { userId = 7, score = 200 }, { userId = 4, score = 60 }, { userId = 2, score = 5 } }
			local t1, p1, c1 = Payout.reward(200, podium, 7, RULES)
			assert((t1 :: any).name == "Gold" and p1 == 1 and c1 == 700)
			local t2, p2, c2 = Payout.reward(60, podium, 4, RULES)
			assert((t2 :: any).name == "Silver" and p2 == 2 and c2 == 350)
			local t3, p3, c3 = Payout.reward(5, podium, 2, RULES)
			assert(
				t3 == nil and p3 == 3 and c3 == 100,
				"on the podium below the first tier still earns the bonus"
			)
			local t4, p4, c4 = Payout.reward(60, podium, 99, RULES)
			assert((t4 :: any).name == "Silver" and p4 == nil and c4 == 150)
			local t5, p5, c5 = Payout.reward(5, podium, 99, RULES)
			assert(t5 == nil and p5 == nil and c5 == 0)
		end,
	},
	{
		name = "decide skips a player with no score, a paid season and the current or a later season",
		run = function()
			local season = closed({})
			assert(Payout.decide(nil, season, 5, 6, 1, 2000, RULES).reason == "no_score")
			assert(Payout.decide(entry(0), season, 5, 6, 1, 2000, RULES).reason == "no_score")
			local paid = Payout.decide(entry(60, true), season, 5, 6, 1, 2000, RULES)
			assert(paid.action == "skip" and paid.reason == "rewarded")
			local current = Payout.decide(entry(60), season, 5, 5, 1, 2000, RULES)
			assert(current.action == "skip" and current.reason == "current")
			assert(Payout.decide(entry(60), season, 5, 4, 1, 2000, RULES).action == "skip")
		end,
	},
	{
		name = "decide opens a missing season, waits on an open one before its end and closes it at the end",
		run = function()
			assert(Payout.decide(entry(60), nil, 5, 6, 1, 2000, RULES).action == "open")
			local early = Payout.decide(entry(60), openSeason(), 5, 6, 1, 999, RULES)
			assert(early.action == "wait" and early.reason == "not_ended", "a clock behind the end waits")
			assert(Payout.decide(entry(60), openSeason(), 5, 6, 1, 1000, RULES).action == "close")
			assert(Payout.decide(entry(60), openSeason(), 5, 6, 1, 5000, RULES).action == "close")
		end,
	},
	{
		name = "decide pays from the stored podium and the player's own score, with plain words",
		run = function()
			local podium = { { userId = 1, score = 200 }, { userId = 2, score = 60 } }
			local d = Payout.decide(entry(200), closed(podium), 5, 6, 1, 2000, RULES)
			assert(d.action == "pay" and d.tier == "Gold" and d.place == 1 and d.coins == 700)
			assert(
				d.text
					== "Season 5 is over. You scored 200 points, reached Gold and placed 1st on the podium. 700 Coins paid.",
				d.text
			)
			local small = Payout.decide(entry(1), closed({}), 5, 6, 3, 2000, RULES)
			assert(small.action == "pay" and small.coins == 0 and small.tier == nil and small.place == nil)
			assert(
				small.text
					== "Season 5 is over. You scored 1 point, fell short of Bronze. No Coins this time.",
				small.text
			)
			local third =
				Payout.decide(entry(5), closed({ {}, {}, { userId = 3, score = 5 } }), 5, 6, 3, 2000, RULES)
			assert(third.place == 3 and string.find(third.text :: string, "3rd on the podium", 1, true))
		end,
	},
	{
		name = "decide does not change what it was given",
		run = function()
			local e, s = entry(60), closed({ { userId = 1, score = 60 } })
			local before = Deep.copy({ e, s })
			Payout.decide(e, s, 5, 6, 1, 2000, RULES)
			assert(Deep.equal({ e, s }, before))
		end,
	},
	{
		name = "apply pays, marks the season paid and leaves score and lifetime alone",
		run = function()
			local p: any = { coins = 10, lifetime = { points = 60 }, seasons = { ["5"] = entry(60) } }
			local d = Payout.decide(p.seasons["5"], closed({}), 5, 6, 1, 2000, RULES)
			local undo = Payout.apply(p, "5", d)
			assert(p.coins == 160 and undo.coins == 150)
			assert(
				p.seasons["5"].rewarded == true
					and p.seasons["5"].tier == "Silver"
					and p.seasons["5"].reward == 150
			)
			assert(p.seasons["5"].score == 60 and p.lifetime.points == 60)
		end,
	},
	{
		name = "after apply the same season decides skip, so a second settle pays nothing",
		run = function()
			local p: any = { coins = 0, lifetime = {}, seasons = { ["5"] = entry(60) } }
			local season = closed({})
			Payout.apply(p, "5", Payout.decide(p.seasons["5"], season, 5, 6, 1, 2000, RULES))
			local again = Payout.decide(p.seasons["5"], season, 5, 6, 1, 2000, RULES)
			assert(again.action == "skip" and again.reason == "rewarded")
		end,
	},
	{
		name = "undo puts a payout back exactly, and relative to now when other things changed meanwhile",
		run = function()
			local p: any = { coins = 10, lifetime = {}, seasons = { ["5"] = entry(60), ["6"] = entry(4) } }
			local before = Deep.copy(p)
			local d = Payout.decide(p.seasons["5"], closed({}), 5, 6, 1, 2000, RULES)
			local undo = Payout.apply(p, "5", d)
			Payout.undo(p, "5", undo)
			assert(Deep.equal(p, before), "undo must restore a payout exactly")
			local undo2 = Payout.apply(p, "5", d)
			p.coins += 7 -- something else credited the player while the save was in flight
			p.seasons["6"].score = 40 -- and a score was recorded
			Payout.undo(p, "5", undo2)
			assert(p.coins == 17 and p.seasons["6"].score == 40, "undo is relative, not a snapshot")
			assert(
				p.seasons["5"].rewarded == false
					and p.seasons["5"].tier == nil
					and p.seasons["5"].reward == nil
			)
		end,
	},
	{
		name = "apply refuses a decision that is not a pay",
		run = function()
			local p: any = { coins = 0, lifetime = {}, seasons = { ["5"] = entry(60) } }
			local ok = pcall(Payout.apply, p, "5", { action = "close" })
			assert(ok == false and p.coins == 0)
		end,
	},
	{
		name = "fuzz: the decision table keeps its invariants and a paid season is never paid twice",
		run = function()
			local rand = lcg(7)
			local seen = { skip = 0, open = 0, close = 0, wait = 0, pay = 0 }
			for _ = 1, 3000 do
				local e: any = if rand(4) == 1 then nil else entry((rand(6) - 1) * 30, rand(3) == 1)
				local state = rand(3)
				local podium = {}
				for place = 1, rand(4) - 1 do
					table.insert(podium, { userId = rand(5), score = 100 - place })
				end
				local season: any = nil
				if state > 1 then
					season = {
						id = 5,
						endsAt = 1000,
						state = if state == 2 then "open" else "closed",
						podium = podium,
					}
				end
				local now = 990 + rand(20)
				local currentId = 4 + rand(3)
				local userId = rand(5)
				local before = Deep.copy({ e, season })
				local d = Payout.decide(e, season, 5, currentId, userId, now, RULES)
				assert(Deep.equal({ e, season }, before), "decide must not mutate")
				seen[d.action] += 1

				local eligible = e ~= nil and e.score > 0 and not e.rewarded and 5 < currentId
				local want: string
				if not eligible then
					want = "skip"
				elseif season == nil then
					want = "open"
				elseif season.state == "open" then
					want = if now >= season.endsAt then "close" else "wait"
				else
					want = "pay"
				end
				assert(d.action == want, `expected {want}, got {d.action}`)

				if d.action == "pay" then
					local best: any = nil
					for _, tier in RULES.tiers do
						if e.score >= tier.min and (best == nil or tier.min > best.min) then
							best = tier
						end
					end
					assert(
						d.tier == (if best then best.name else nil),
						"the tier is the highest threshold met"
					)
					local place: any = nil
					for i, row in podium do
						if row.userId == userId and place == nil then
							place = i
						end
					end
					assert(d.place == place)
					local coins = (if best then best.coins else 0)
						+ (if place then RULES.podiumBonus[place] or 0 else 0)
					assert(d.coins == coins and (d.coins :: number) >= 0)
					assert(d.text ~= nil and d.text ~= "")
					local profile: any = { coins = 0, lifetime = {}, seasons = { ["5"] = Deep.copy(e) } }
					Payout.apply(profile, "5", d)
					local again =
						Payout.decide(profile.seasons["5"], season, 5, currentId, userId, now, RULES)
					assert(again.action == "skip" and profile.coins == coins)
				end
			end
			for action, count in seen do
				assert(count > 0, `the fuzz never produced {action}`)
			end
		end,
	},
}
