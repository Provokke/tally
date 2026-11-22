--!strict
-- What a player is owed for a finished season, decided from facts and nothing else: the player's
-- own score and paid flag, the season key as stored, and which season this server believes is
-- current. Pure: it never reads a clock or a store. Tally runs the reads and writes it asks for.
--
-- Tier Coins come from the player's own score, so they never depend on ranks. The podium bonus
-- comes from the podium frozen into the stored close, never from a live read.
local Payout = {}

export type Tier = { name: string, min: number, coins: number }
export type Rules = { tiers: { Tier }, podiumBonus: { number } }
export type Entry = { score: number, rewarded: boolean, tier: string?, reward: number? }
export type Podium = { { userId: number, score: number } }
export type SeasonView = { id: number, endsAt: number, state: string, podium: Podium }
export type Decision = {
	action: "skip" | "open" | "close" | "wait" | "pay",
	reason: string?,
	tier: string?,
	place: number?,
	coins: number?,
	text: string?,
}
export type Undo = { key: string, coins: number }

function Payout.tierFor(score: number, tiers: { Tier }): Tier?
	local best: Tier? = nil
	for _, tier in tiers do
		if score >= tier.min and (best == nil or tier.min > best.min) then
			best = tier
		end
	end
	return best
end

function Payout.placeOf(podium: Podium, userId: number): number?
	for place, row in podium do
		if row.userId == userId then
			return place
		end
	end
	return nil
end

function Payout.reward(score: number, podium: Podium, userId: number, rules: Rules): (Tier?, number?, number)
	local tier = Payout.tierFor(score, rules.tiers)
	local place = Payout.placeOf(podium, userId)
	local bonus = if place ~= nil then rules.podiumBonus[place] or 0 else 0
	return tier, place, (if tier ~= nil then tier.coins else 0) + bonus
end

local function ordinal(n: number): string
	local last, lastTwo = n % 10, n % 100
	local suffix = "th"
	if lastTwo < 11 or lastTwo > 13 then
		if last == 1 then
			suffix = "st"
		elseif last == 2 then
			suffix = "nd"
		elseif last == 3 then
			suffix = "rd"
		end
	end
	return `{n}{suffix}`
end

local function plural(n: number, one: string, many: string): string
	return `{n} {if n == 1 then one else many}`
end

local function lowestTier(tiers: { Tier }): Tier?
	local lowest: Tier? = nil
	for _, tier in tiers do
		if lowest == nil or tier.min < lowest.min then
			lowest = tier
		end
	end
	return lowest
end

local function describe(
	id: number,
	score: number,
	tier: Tier?,
	place: number?,
	coins: number,
	rules: Rules
): string
	local clauses: { string } = {}
	if tier ~= nil then
		table.insert(clauses, `reached {tier.name}`)
	else
		local lowest = lowestTier(rules.tiers)
		if lowest ~= nil then
			table.insert(clauses, `fell short of {lowest.name}`)
		end
	end
	if place ~= nil then
		table.insert(clauses, `placed {ordinal(place)} on the podium`)
	end
	local text = `Season {id} is over. You scored {plural(score, "point", "points")}`
	if #clauses > 0 then
		text ..= ", " .. table.concat(clauses, " and ")
	end
	text ..= "."
	if coins > 0 then
		text ..= ` {plural(coins, "Coin", "Coins")} paid.`
	else
		text ..= " No Coins this time."
	end
	return text
end

-- The whole decision table. `skip` and `wait` mean do nothing now; `open` and `close` ask Tally
-- for a write and then decide again from the value that write returned; `pay` is final.
function Payout.decide(
	entry: Entry?,
	season: SeasonView?,
	id: number,
	currentId: number,
	userId: number,
	now: number,
	rules: Rules
): Decision
	if entry == nil or entry.score <= 0 then
		return { action = "skip", reason = "no_score" }
	end
	if entry.rewarded then
		return { action = "skip", reason = "rewarded" }
	end
	if id >= currentId then
		return { action = "skip", reason = "current" }
	end
	if season == nil then
		return { action = "open" }
	end
	if season.state == "open" then
		if now >= season.endsAt then
			return { action = "close" }
		end
		return { action = "wait", reason = "not_ended" }
	end
	local tier, place, coins = Payout.reward(entry.score, season.podium, userId, rules)
	return {
		action = "pay",
		tier = if tier ~= nil then tier.name else nil,
		place = place,
		coins = coins,
		text = describe(id, entry.score, tier, place, coins, rules),
	}
end

-- Applies a pay decision to the in-memory profile in one change with no yield: the Coins, and
-- the flag that records they were paid. Tally saves once, straight after.
function Payout.apply(profile: any, key: string, decision: Decision): Undo
	assert(decision.action == "pay", "apply needs a pay decision")
	local coins = decision.coins :: number
	local entry = profile.seasons[key]
	entry.rewarded = true
	entry.tier = decision.tier
	entry.reward = coins
	profile.coins += coins
	return { key = key, coins = coins }
end

-- Rolls a failed payout back relative to the current values, not to a snapshot: a score recorded
-- while the save was in flight is kept.
function Payout.undo(profile: any, key: string, undo: Undo)
	local entry = profile.seasons[key]
	if entry ~= nil then
		entry.rewarded = false
		entry.tier = nil
		entry.reward = nil
	end
	profile.coins -= undo.coins
end

return Payout
