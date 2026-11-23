--!strict
-- The Studio demo seed. Pure: it plans what to put on the board and in the profile, and the server
-- script applies it (only in Studio, over the in-memory stores). Ten pretend players fill the
-- current board, and when there is an earlier season, the real player finished it with 85 points
-- and has not been paid, so the first settle closes that season and shows a reward notice.
local DemoSeed = {}

export type Plan = {
	board: { [number]: { [string]: number } },
	profile: { [string]: { score: number, rewarded: boolean } },
}

DemoSeed.PlayerScore = 85
local PRETEND = 10

-- Ten ids from 101 up that are never the real player's, so the real player is never paired with one.
local function pretendIds(userId: number): { number }
	local ids: { number } = {}
	local id = 101
	while #ids < PRETEND do
		if id ~= userId then
			table.insert(ids, id)
		end
		id += 1
	end
	return ids
end

function DemoSeed.plan(userId: number, currentId: number): Plan
	local ids = pretendIds(userId)
	local current: { [string]: number } = {}
	for i, id in ids do
		current[tostring(id)] = i * 20 -- 20 to 200, distinct
	end
	local plan: Plan = { board = { [currentId] = current }, profile = {} }
	if currentId > 1 then
		local prior: { [string]: number } = {}
		for i, id in ids do
			prior[tostring(id)] = (PRETEND + 1 - i) * 20 - 5 -- 195 down to 15, distinct, differing from the current board
		end
		prior[tostring(userId)] = DemoSeed.PlayerScore
		plan.board[currentId - 1] = prior
		plan.profile[tostring(currentId - 1)] = { score = DemoSeed.PlayerScore, rewarded = false }
	end
	return plan
end

return DemoSeed
