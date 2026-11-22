--!strict
local BoardLogic = require("../../src/shared/BoardLogic")
local Config = require("../../src/shared/Config")

local function entries(scores: { number }): any
	local out = {}
	for i, score in scores do
		table.insert(out, { userId = 100 + i, score = score })
	end
	return out
end

return {
	{
		name = "timeLeft formats days, hours, minutes, seconds and ended",
		run = function()
			assert(BoardLogic.timeLeft(90061) == "1d 01h" and BoardLogic.timeLeft(86400) == "1d 00h")
			assert(BoardLogic.timeLeft(7500) == "2h 05m" and BoardLogic.timeLeft(3600) == "1h 00m")
			assert(BoardLogic.timeLeft(303) == "5m 03s" and BoardLogic.timeLeft(59.9) == "59s")
			assert(BoardLogic.timeLeft(0) == "Ended" and BoardLogic.timeLeft(-5) == "Ended")
		end,
	},
	{
		name = "coins groups thousands and says Coin for one",
		run = function()
			assert(BoardLogic.coins(0) == "0 Coins" and BoardLogic.coins(1) == "1 Coin")
			assert(BoardLogic.coins(999) == "999 Coins" and BoardLogic.coins(1000) == "1,000 Coins")
			assert(BoardLogic.coins(1234567) == "1,234,567 Coins")
		end,
	},
	{
		name = "estimateRank counts the entries ahead, and is nil off the end of a full cache",
		run = function()
			local list = entries({ 90, 70, 50 })
			assert(BoardLogic.estimateRank(list, 5, 100) == 1)
			assert(BoardLogic.estimateRank(list, 5, 60) == 3)
			assert(
				BoardLogic.estimateRank(list, 5, 10) == 4,
				"a list with room has everyone, so last is rank 4"
			)
			assert(
				BoardLogic.estimateRank(list, 3, 10) == nil,
				"a full cache can't say where a low score sits"
			)
			assert(
				BoardLogic.estimateRank(list, 3, 50) == nil,
				"a tie with the last entry of a full cache is unknown"
			)
			assert(BoardLogic.estimateRank(list, 3, 51) == 3)
			assert(BoardLogic.estimateRank({}, 3, 5) == 1)
			assert(BoardLogic.estimateRank(list, 5, 0) == nil)
		end,
	},
	{
		name = "rankText says it is an estimate",
		run = function()
			assert(BoardLogic.rankText(3, 60, 50) == "About #3")
			assert(BoardLogic.rankText(nil, 60, 50) == "Outside the top 50")
			assert(BoardLogic.rankText(nil, 0, 50) == "Not on the board yet")
		end,
	},
	{
		name = "tierProgress and tierText",
		run = function()
			local tiers = Config.Tiers
			local none = BoardLogic.tierProgress(4, tiers)
			assert(none.reached == nil and none.next == "Bronze" and none.toNext == 6)
			assert(math.abs(none.fraction - 0.4) < 1e-9)
			assert(BoardLogic.tierText(none) == "6 more points to Bronze")
			local mid = BoardLogic.tierProgress(100, tiers)
			assert(mid.reached == "Silver" and mid.next == "Gold" and mid.toNext == 50)
			assert(math.abs(mid.fraction - 0.5) < 1e-9)
			assert(BoardLogic.tierText(mid) == "Silver reached. 50 more points to Gold")
			local top = BoardLogic.tierProgress(500, tiers)
			assert(top.reached == "Gold" and top.next == nil and top.fraction == 1)
			assert(BoardLogic.tierText(top) == "Gold reached. Top tier")
			assert(
				BoardLogic.tierProgress(1, tiers).toNext == 9
					and BoardLogic.tierText(BoardLogic.tierProgress(9, tiers)) == "1 more point to Bronze"
			)
		end,
	},
	{
		name = "pageRows slices a page with whole-list ranks and pins the player's row when they are off it",
		run = function()
			local list = entries({ 90, 80, 70, 60, 50 })
			local first = BoardLogic.pageRows(list, 1, 2, 999, 30, 8)
			assert(#first == 3 and first[1].rank == 1 and first[2].rank == 2 and first[3].pinned == true)
			assert(first[3].isMe == true and first[3].rank == 8 and first[3].score == 30)
			local second = BoardLogic.pageRows(list, 2, 2, 999, 30, 8)
			assert(second[1].rank == 3 and second[2].rank == 4)
			local onPage = BoardLogic.pageRows(list, 1, 2, 102, 80, 2)
			assert(#onPage == 2 and onPage[2].isMe == true and onPage[2].pinned == false)
			assert(#BoardLogic.pageRows(list, 1, 2, 999, 0, nil) == 2, "no score, no pinned row")
			assert(#BoardLogic.pageRows(list, 9, 2, 999, 0, nil) == 0)
		end,
	},
	{
		name = "streakText for each state",
		run = function()
			assert(
				BoardLogic.streakText({ count = 0, canClaim = true, broken = false, nextReward = 10 })
					== "Claim 10 Coins to start a streak."
			)
			assert(
				BoardLogic.streakText({ count = 3, canClaim = true, broken = false, nextReward = 20 })
					== "Day 3 streak. Claim 20 Coins."
			)
			assert(
				BoardLogic.streakText({ count = 0, canClaim = true, broken = true, nextReward = 10 })
					== "Your streak ended. Claim 10 Coins to start again."
			)
			assert(
				BoardLogic.streakText({ count = 3, canClaim = false, broken = false, nextReward = 30 })
					== "Claimed today. Day 3. Tomorrow: 30 Coins."
			)
		end,
	},
	{
		name = "every reason the server gives has plain words, and an unknown one still has some",
		run = function()
			for _, reason in
				{ "already_claimed", "save_failed", "busy", "slow_down", "error", "no_profile", "bad_day" }
			do
				local text = BoardLogic.reasonText(reason)
				assert(text ~= "" and text ~= "That didn't work.", reason)
			end
			assert(
				BoardLogic.reasonText("nope") == "That didn't work."
					and BoardLogic.reasonText(nil) == "That didn't work."
			)
			assert(BoardLogic.resultText("claim_streak", true, nil, 15) == "You claimed 15 Coins.")
			assert(
				BoardLogic.resultText("claim_streak", false, "already_claimed", nil)
					== BoardLogic.reasonText("already_claimed")
			)
			assert(BoardLogic.resultText("board_page", true, nil, nil) == nil)
		end,
	},
}
