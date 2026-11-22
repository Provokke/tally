--!strict
-- Everything the scoreboard says or works out that doesn't need Roblox: time, Coins, rank
-- estimates, tier progress, page rows and plain-words messages. Pure, and tested under Lune.
local BoardLogic = {}

export type Entry = { userId: number, score: number }
export type Row = { rank: number?, userId: number, score: number, isMe: boolean, pinned: boolean }
export type Tier = { name: string, min: number, coins: number }
export type Progress = { reached: string?, next: string?, toNext: number?, fraction: number }
export type StreakState = { count: number, canClaim: boolean, broken: boolean, nextReward: number }

function BoardLogic.timeLeft(seconds: number): string
	if seconds <= 0 then
		return "Ended"
	end
	local s = math.floor(seconds)
	local days = math.floor(s / 86400)
	local hours = math.floor((s % 86400) / 3600)
	local minutes = math.floor((s % 3600) / 60)
	if days >= 1 then
		return string.format("%dd %02dh", days, hours)
	end
	if hours >= 1 then
		return string.format("%dh %02dm", hours, minutes)
	end
	if minutes >= 1 then
		return string.format("%dm %02ds", minutes, s % 60)
	end
	return string.format("%ds", s)
end

function BoardLogic.coins(n: number): string
	local whole = math.floor(n)
	local digits = string.format("%d", math.abs(whole))
	local grouped = ""
	local count = 0
	for i = #digits, 1, -1 do
		if count > 0 and count % 3 == 0 then
			grouped = "," .. grouped
		end
		grouped = string.sub(digits, i, i) .. grouped
		count += 1
	end
	return `{if whole < 0 then "-" else ""}{grouped} {if whole == 1 then "Coin" else "Coins"}`
end

-- The rank the cached entries give a score, or nil when the cache can't say: no score, or a full
-- list the score does not beat the end of.
function BoardLogic.estimateRank(entries: { Entry }, size: number, score: number): number?
	if score <= 0 then
		return nil
	end
	if #entries >= size and score <= entries[#entries].score then
		return nil
	end
	local ahead = 0
	for _, entry in entries do
		if entry.score > score then
			ahead += 1
		end
	end
	return ahead + 1
end

function BoardLogic.rankText(rank: number?, score: number, size: number): string
	if score <= 0 then
		return "Not on the board yet"
	end
	if rank == nil then
		return `Outside the top {size}`
	end
	return `About #{rank}`
end

function BoardLogic.tierProgress(score: number, tiers: { Tier }): Progress
	local reached: Tier? = nil
	local nextTier: Tier? = nil
	for _, tier in tiers do
		if score >= tier.min then
			if reached == nil or tier.min > reached.min then
				reached = tier
			end
		elseif nextTier == nil or tier.min < nextTier.min then
			nextTier = tier
		end
	end
	if nextTier == nil then
		return {
			reached = if reached ~= nil then reached.name else nil,
			next = nil,
			toNext = nil,
			fraction = 1,
		}
	end
	local from = if reached ~= nil then reached.min else 0
	local fraction = math.clamp((score - from) / (nextTier.min - from), 0, 1)
	return {
		reached = if reached ~= nil then reached.name else nil,
		next = nextTier.name,
		toNext = nextTier.min - score,
		fraction = fraction,
	}
end

function BoardLogic.tierText(progress: Progress): string
	local head = if progress.reached ~= nil then `{progress.reached} reached. ` else ""
	if progress.next == nil or progress.toNext == nil then
		return head .. "Top tier"
	end
	local unit = if progress.toNext == 1 then "point" else "points"
	return `{head}{progress.toNext} more {unit} to {progress.next}`
end

function BoardLogic.pageRows(
	entries: { Entry },
	page: number,
	pageSize: number,
	myUserId: number,
	myScore: number,
	myRank: number?
): { Row }
	local rows: { Row } = {}
	local first = (page - 1) * pageSize + 1
	local seen = false
	for i = first, math.min(first + pageSize - 1, #entries) do
		local entry = entries[i]
		local isMe = entry.userId == myUserId
		seen = seen or isMe
		table.insert(
			rows,
			{ rank = i, userId = entry.userId, score = entry.score, isMe = isMe, pinned = false }
		)
	end
	if not seen and myScore > 0 and #rows > 0 then
		table.insert(rows, { rank = myRank, userId = myUserId, score = myScore, isMe = true, pinned = true })
	end
	return rows
end

function BoardLogic.streakText(state: StreakState): string
	local reward = BoardLogic.coins(state.nextReward)
	if not state.canClaim then
		return `Claimed today. Day {state.count}. Tomorrow: {reward}.`
	end
	if state.broken then
		return `Your streak ended. Claim {reward} to start again.`
	end
	if state.count == 0 then
		return `Claim {reward} to start a streak.`
	end
	return `Day {state.count} streak. Claim {reward}.`
end

local REASONS: { [string]: string } = {
	already_claimed = "You have already claimed today. The day changes at midnight UTC.",
	save_failed = "Couldn't save that. Try again.",
	busy = "Hold on, still working on your last request.",
	no_profile = "Your data isn't loaded yet.",
	bad_day = "The server's day looks wrong. Try again in a moment.",
}

function BoardLogic.reasonText(reason: string?): string
	return if reason ~= nil and REASONS[reason] ~= nil then REASONS[reason] else "That didn't work."
end

function BoardLogic.resultText(action: string, ok: boolean, reason: string?, reward: number?): string?
	if action == "claim_streak" then
		if ok and reward ~= nil then
			return `You claimed {BoardLogic.coins(reward)}.`
		end
		return BoardLogic.reasonText(reason)
	end
	if not ok then
		return BoardLogic.reasonText(reason)
	end
	return nil
end

return BoardLogic
