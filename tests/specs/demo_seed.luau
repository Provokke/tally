--!strict
local Deep = require("../fakes/Deep")
local DemoSeed = require("../../src/server/DemoSeed")

local function count(map: { [string]: number }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

return {
	{
		name = "the plan is deterministic",
		run = function()
			assert(Deep.equal(DemoSeed.plan(7, 5), DemoSeed.plan(7, 5)))
		end,
	},
	{
		name = "the current board has ten pretend players with strictly distinct scores from 20 to 200, none the player",
		run = function()
			local current = DemoSeed.plan(7, 5).board[5]
			assert(count(current) == 10)
			local seen: { [number]: boolean } = {}
			for key, score in current do
				assert(key ~= "7", "the player is not on the current board")
				assert(score >= 20 and score <= 200 and score % 20 == 0, tostring(score))
				assert(not seen[score], "distinct scores")
				seen[score] = true
			end
			assert(current["101"] ~= nil and current["110"] ~= nil)
		end,
	},
	{
		name = "season 1 has no prior season",
		run = function()
			local plan = DemoSeed.plan(7, 1)
			assert(plan.board[1] ~= nil and plan.board[0] == nil)
			assert(next(plan.profile) == nil, "no profile entry")
			assert(Deep.equal(plan.board, { [1] = plan.board[1] }), "only the current board")
		end,
	},
	{
		name = "with a current season of 5 the player finished season 4 with 85 unpaid, on its board only",
		run = function()
			local plan = DemoSeed.plan(7, 5)
			assert(Deep.equal(plan.profile, { ["4"] = { score = 85, rewarded = false } }))
			assert(plan.board[4]["7"] == 85, "the player is on the season 4 board")
			assert(plan.board[5]["7"] == nil, "and not on the current one")
			assert(count(plan.board[4]) == 11)
			local seen: { [number]: boolean } = {}
			for key, score in plan.board[4] do
				assert(not seen[score], "distinct scores")
				seen[score] = true
				if key ~= "7" then
					assert(score ~= plan.board[5][key], "the pretend scores differ from the current board")
				end
			end
		end,
	},
	{
		name = "the pretend ids never equal the player, for every userId from 1 to 200",
		run = function()
			for userId = 1, 200 do
				local plan = DemoSeed.plan(userId, 3)
				assert(count(plan.board[3]) == 10, `userId {userId}`)
				assert(plan.board[3][tostring(userId)] == nil, `userId {userId} on the current board`)
				assert(plan.board[2][tostring(userId)] == 85, `userId {userId} missing from the prior board`)
				assert(count(plan.board[2]) == 11, `userId {userId} paired with a pretend id`)
			end
		end,
	},
}
