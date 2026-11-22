--!strict
-- The daily streak. The day is floor(os.time() / 86400), which is UTC, not the player's local
-- day. Pure: the caller passes today in. Tally applies a claim, its Coins and the new streak in
-- one profile save.
local Streak = {}

export type Streak = { day: number, count: number, earned: number }
export type Claimed = { streak: Streak, reward: number }
export type State = { count: number, canClaim: boolean, broken: boolean, nextReward: number }

function Streak.dayOf(now: number): number
	return math.floor(now / 86400)
end

function Streak.new(): Streak
	return { day = 0, count = 0, earned = 0 }
end

local function rewardFor(count: number, rewards: { number }): number
	return rewards[math.min(count, #rewards)]
end

function Streak.claim(streak: Streak?, today: number, rewards: { number }): (Claimed?, string?)
	if type(today) ~= "number" or today % 1 ~= 0 or today < 1 then
		return nil, "bad_day"
	end
	if #rewards == 0 then
		return nil, "no_rewards"
	end
	local current = streak or Streak.new()
	if today <= current.day then
		return nil, "already_claimed"
	end
	local count = if today == current.day + 1 then current.count + 1 else 1
	local reward = rewardFor(count, rewards)
	return { streak = { day = today, count = count, earned = current.earned + reward }, reward = reward }, nil
end

function Streak.state(streak: Streak?, today: number, rewards: { number }): State
	local current = streak or Streak.new()
	local canClaim = today > current.day
	local broken = current.day > 0 and today > current.day + 1
	local nextCount
	if canClaim then
		nextCount = if today == current.day + 1 then current.count + 1 else 1
	else
		nextCount = current.count + 1
	end
	return {
		count = if broken then 0 else current.count,
		canClaim = canClaim,
		broken = broken,
		nextReward = rewardFor(nextCount, rewards),
	}
end

return Streak
