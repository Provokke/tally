--!strict
local Deep = require("../fakes/Deep")
local Season = require("../../src/server/Season")

local function open(): any
	local season = Season.open(nil, 3, 1000, 2000)
	assert(season ~= nil)
	return season
end

return {
	{
		name = "idAt is nil before the epoch and counts seasons from 1",
		run = function()
			assert(Season.idAt(1000, 100, 999) == nil)
			assert(Season.idAt(1000, 100, 1000) == 1)
			assert(Season.idAt(1000, 100, 1099) == 1)
			assert(Season.idAt(1000, 100, 1100) == 2)
			assert(Season.idAt(1000, 100, 1250.9) == 3)
			assert(Season.idAt(1000, 0, 1500) == nil, "a zero length is refused, not a divide by zero")
		end,
	},
	{
		name = "window gives the start and end of a season, and ends where the next begins",
		run = function()
			local s1, e1 = Season.window(1000, 100, 1)
			local s2, e2 = Season.window(1000, 100, 2)
			assert(s1 == 1000 and e1 == 1100)
			assert(s2 == e1 and e2 == 1200)
		end,
	},
	{
		name = "key is season/<id>",
		run = function()
			assert(Season.key(12) == "season/12")
		end,
	},
	{
		name = "open on nothing makes an open season with an empty podium",
		run = function()
			local season = open()
			assert(season.id == 3 and season.startsAt == 1000 and season.endsAt == 2000)
			assert(season.state == "open" and #season.podium == 0)
			assert(season.closedBy == nil and season.closedAt == nil)
		end,
	},
	{
		name = "open on an existing key says exists and changes nothing, even when it is closed",
		run = function()
			local existing = open()
			local closed = Season.close(existing, 2000, { { userId = 1, score = 5 } }, "A") :: any
			for _, current in { existing, closed } do
				local before = Deep.copy(current)
				local out, reason = Season.open(current, 3, 1000, 2000)
				assert(out == nil and reason == "exists")
				assert(Deep.equal(current, before), "open must not change its input")
			end
		end,
	},
	{
		name = "open refuses a malformed season",
		run = function()
			local _, a = Season.open(nil, 0, 1000, 2000)
			local _, b = Season.open(nil, 1.5, 1000, 2000)
			local _, c = Season.open(nil, 3, 2000, 2000)
			local _, d = Season.open(nil, 3, 2000, 1000)
			assert(a == "bad_season" and b == "bad_season" and c == "bad_season" and d == "bad_season")
		end,
	},
	{
		name = "close refuses missing, not_open and not_ended, in that order, and writes nothing",
		run = function()
			local missing, why = Season.close(nil, 5000, {}, "A")
			assert(missing == nil and why == "missing")
			local season = open()
			local early, early_why = Season.close(season, 1999, {}, "A")
			assert(early == nil and early_why == "not_ended")
			local closed = Season.close(season, 2000, {}, "A") :: any
			local again, again_why = Season.close(closed, 5000, {}, "B")
			assert(again == nil and again_why == "not_open")
			local both, both_why = Season.close(closed, 1, {}, "B")
			assert(both == nil and both_why == "not_open", "not_open is checked before not_ended")
		end,
	},
	{
		name = "close at the end moment stores the podium, who closed it and when",
		run = function()
			local season = open()
			local podium = { { userId = 7, score = 90 }, { userId = 4, score = 80 } }
			local closed = Season.close(season, 2000, podium, "JOB-A") :: any
			assert(closed.state == "closed" and closed.id == 3 and closed.endsAt == 2000)
			assert(closed.closedBy == "JOB-A" and closed.closedAt == 2000)
			assert(Deep.equal(closed.podium, podium))
			podium[1].score = 1 -- the stored podium is a copy
			assert(closed.podium[1].score == 90, "close must copy the podium")
		end,
	},
	{
		name = "the first close wins: a second closer with another podium is refused and the stored one stands",
		run = function()
			local stored: any = open()
			local first = Season.close(stored, 2000, { { userId = 1, score = 50 } }, "A") :: any
			stored = first
			local second, reason = Season.close(stored, 2003, { { userId = 2, score = 99 } }, "B")
			assert(second == nil and reason == "not_open")
			assert(stored.podium[1].userId == 1 and stored.closedBy == "A")
		end,
	},
	{
		name = "close does not mutate its input, and running it twice on one input gives equal outputs",
		run = function()
			local season = open()
			local before = Deep.copy(season)
			local a = Season.close(season, 2500, { { userId = 1, score = 5 } }, "A")
			local b = Season.close(season, 2500, { { userId = 1, score = 5 } }, "A")
			assert(Deep.equal(season, before))
			assert(Deep.equal(a, b))
		end,
	},
	{
		name = "matches is true only for the window the config gives, whatever the state, and false for a non-table",
		run = function()
			local season: any = Season.open(nil, 3, 1200, 1300)
			assert(Season.matches(season, 1200, 1300))
			assert(
				Season.matches(Season.close(season, 1300, {}, "A"), 1200, 1300),
				"a closed key is judged the same"
			)
			assert(not Season.matches(season, 1200, 1400), "another end")
			assert(not Season.matches(season, 1100, 1300), "another start")
			assert(not Season.matches(nil, 1200, 1300) and not Season.matches(5, 1200, 1300))
		end,
	},
}
