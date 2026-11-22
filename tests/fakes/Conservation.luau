--!strict
-- The settled-world check for season rewards: after every settle has finished, no Coin has been
-- made or lost. Records are the shared store's table as it is audited: `profile/<id>` holds a
-- player's saved data and `season/<id>` is a season key. Keys are visited in sorted order, so
-- the reason reported is the same on every run.
local Conservation = {}

export type Options = {
	currentId: number, -- the season this world is in: older scored seasons must be paid
	mode: "sum" | "best",
	settled: boolean?, -- false skips the check that old scored seasons are paid and closed
	stat: string?, -- the lifetime stat, "points" when not given
}

local PROFILE_PREFIX = "profile/"

local function sortedKeys(t: { [any]: any }): { any }
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	return keys
end

function Conservation.check(
	records: { [string]: any },
	startCoins: { [number]: number },
	opts: Options
): (boolean, string?)
	local profiles: { [number]: any } = {}
	for key, record in records do
		if string.sub(key, 1, #PROFILE_PREFIX) == PROFILE_PREFIX then
			local userId = tonumber(string.sub(key, #PROFILE_PREFIX + 1))
			if userId ~= nil then
				profiles[userId] = record
			end
		end
	end
	-- A user who never saved holds exactly their start Coins: nothing they did reached the store.
	for userId, coins in startCoins do
		if profiles[userId] == nil then
			profiles[userId] = {
				coins = coins,
				lifetime = {},
				seasons = {},
				streak = { day = 0, count = 0, earned = 0 },
			}
		end
	end
	local users = sortedKeys(profiles)
	local stat = opts.stat or "points"

	-- A payout without a record, or a record without a payout.
	for _, userId in users do
		local seasons = profiles[userId].seasons or {}
		for _, key in sortedKeys(seasons) do
			local entry = seasons[key]
			if entry.rewarded and type(entry.reward) ~= "number" then
				return false, `player {userId} season {key}: rewarded with no reward recorded`
			end
			if entry.reward ~= nil and not entry.rewarded then
				return false, `player {userId} season {key}: a reward recorded but not rewarded`
			end
		end
	end

	-- Coins: the start, the season rewards and the streak, and nothing else.
	for _, userId in users do
		local profile = profiles[userId]
		local start = startCoins[userId]
		if start == nil then
			return false, `player {userId}: no start Coins given`
		end
		local expected = start + (if profile.streak ~= nil then profile.streak.earned or 0 else 0)
		for _, key in sortedKeys(profile.seasons or {}) do
			local entry = profile.seasons[key]
			if entry.rewarded then
				expected += entry.reward
			end
		end
		if profile.coins ~= expected then
			return false, `player {userId}: holds {profile.coins} Coins, expected {expected}`
		end
	end

	-- A season event never moves a lifetime stat in sum mode: it holds exactly the season scores.
	if opts.mode == "sum" then
		for _, userId in users do
			local profile = profiles[userId]
			local total = 0
			for _, entry in profile.seasons or {} do
				total += entry.score
			end
			local lifetime = (profile.lifetime or {})[stat] or 0
			if lifetime ~= total then
				return false, `player {userId}: lifetime {stat} is {lifetime}, the seasons sum to {total}`
			end
		end
	end

	-- Every old scored season is paid, and its key is closed.
	if opts.settled ~= false then
		for _, userId in users do
			local seasons = profiles[userId].seasons or {}
			for _, key in sortedKeys(seasons) do
				local entry = seasons[key]
				local id = tonumber(key)
				if id ~= nil and id < opts.currentId and entry.score > 0 then
					if not entry.rewarded then
						return false, `player {userId} season {key}: scored {entry.score} and was never paid`
					end
					local stored = records[`season/{id}`]
					if stored == nil or stored.state ~= "closed" then
						return false, `player {userId} season {key}: the season key is missing or still open`
					end
				end
			end
		end
	end

	-- A season that paid anyone is closed, settled or not.
	for _, userId in users do
		local seasons = profiles[userId].seasons or {}
		for _, key in sortedKeys(seasons) do
			if seasons[key].rewarded then
				local stored = records[`season/{key}`]
				if stored == nil or stored.state ~= "closed" then
					return false, `player {userId} season {key}: paid from a key that is not closed`
				end
			end
		end
	end
	return true, nil
end

return Conservation
