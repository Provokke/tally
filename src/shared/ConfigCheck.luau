--!strict
-- Start-up sanity check for Config. Returns true, or false and a reason that names the field.
-- It never throws, whatever shape it is handed.
local ConfigCheck = {}

local function isNumber(v: any): boolean
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function isWhole(v: any, min: number): boolean
	return isNumber(v) and v >= min and v % 1 == 0
end

-- The longest name a store or a stat may have.
local MAX_NAME = 32

local NUMBERS = {
	"SchemaVersion",
	"AutosaveSeconds",
	"LeaseSeconds",
	"LoadRetries",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"Epoch",
	"SeasonLengthSeconds",
	"DemoSeasonSeconds",
	"StartingCoins",
	"MaxPointsPerCall",
	"PodiumSize",
	"SettleSeconds",
	"CloseGraceSeconds",
	"PodiumWaitSeconds",
	"SeasonTickSeconds",
	"BoardPushSeconds",
	"BoardRefreshSeconds",
	"BoardCacheSize",
	"BoardPageSize",
	"NoticeCap",
}

local NAMES = { "DataStoreName", "SeasonStoreName", "BoardStorePrefix", "ScoreStat" }

-- Whole numbers with a floor. The starting coins and the epoch may be zero, the rest need one.
local WHOLE_FLOORS: { { any } } = {
	{ "SchemaVersion", 1 },
	{ "LoadRetries", 1 },
	{ "MaxPointsPerCall", 1 },
	{ "PodiumSize", 1 },
	{ "BoardPageSize", 1 },
	{ "NoticeCap", 1 },
	{ "StartingCoins", 0 },
	{ "Epoch", 0 },
}

local ABOVE_ZERO = {
	"AutosaveSeconds",
	"RetryBaseSeconds",
	"CloseTimeoutSeconds",
	"SeasonLengthSeconds",
	"DemoSeasonSeconds",
	"SettleSeconds",
	"CloseGraceSeconds",
	"PodiumWaitSeconds",
	"SeasonTickSeconds",
	"BoardPushSeconds",
	"BoardRefreshSeconds",
}

-- A list of exactly `count` entries (count nil: any number, at least one), each whole and 0 or more.
local function isCoinList(v: any, count: number?): boolean
	if type(v) ~= "table" then
		return false
	end
	local size = 0
	for k, coins in v do
		if type(k) ~= "number" or not isWhole(coins, 0) then
			return false
		end
		size += 1
	end
	if size ~= #v then
		return false
	end
	if count == nil then
		return size >= 1
	end
	return size == count
end

function ConfigCheck.check(config: any): (boolean, string?)
	if type(config) ~= "table" then
		return false, "config must be a table"
	end
	for _, field in NUMBERS do
		if not isNumber(config[field]) then
			return false, `{field} must be a number`
		end
	end
	for _, field in NAMES do
		local v = config[field]
		if type(v) ~= "string" or v == "" or #v > MAX_NAME then
			return false, `{field} must be a string of 1 to {MAX_NAME} characters`
		end
	end
	for _, entry in WHOLE_FLOORS do
		local field, floor = entry[1], entry[2]
		if not isWhole(config[field], floor) then
			return false, `{field} must be a whole number of {floor} or more`
		end
	end
	for _, field in ABOVE_ZERO do
		if config[field] <= 0 then
			return false, `{field} must be above 0`
		end
	end
	if not isWhole(config.BoardCacheSize, 1) or config.BoardCacheSize > 100 then
		return false, "BoardCacheSize must be a whole number from 1 to 100"
	end
	if config.BoardCacheSize < config.BoardPageSize then
		return false, "BoardCacheSize must not be below BoardPageSize"
	end
	if config.BoardCacheSize < config.PodiumSize then
		return false, "BoardCacheSize must not be below PodiumSize"
	end
	if config.ScoreMode ~= "sum" and config.ScoreMode ~= "best" then
		return false, 'ScoreMode must be "sum" or "best"'
	end
	if not isCoinList(config.PodiumBonus, config.PodiumSize) then
		return false, "PodiumBonus must hold exactly PodiumSize whole numbers of 0 or more"
	end
	if config.LeaseSeconds <= config.AutosaveSeconds then
		return false, "LeaseSeconds must be above AutosaveSeconds"
	end

	local tiers = config.Tiers
	if type(tiers) ~= "table" or #tiers == 0 then
		return false, "Tiers must be a non-empty list"
	end
	local seen: { [string]: boolean } = {}
	local previous = 0
	for i, tier in tiers do
		if type(i) ~= "number" or type(tier) ~= "table" then
			return false, "Tiers must be a list of tables"
		end
		if type(tier.name) ~= "string" or tier.name == "" then
			return false, `Tiers[{i}].name must be a non-empty string`
		end
		if not isWhole(tier.min, 1) then
			return false, `Tiers[{i}].min must be a whole number of 1 or more`
		end
		if not isWhole(tier.coins, 0) then
			return false, `Tiers[{i}].coins must be a whole number of 0 or more`
		end
		if seen[tier.name] then
			return false, `Tiers name {tier.name} is used twice`
		end
		seen[tier.name] = true
		if tier.min <= previous then
			return false, "Tiers must be in strictly ascending order of min"
		end
		previous = tier.min
	end

	if not isCoinList(config.StreakRewards, nil) then
		return false, "StreakRewards must be a non-empty list of whole numbers of 0 or more"
	end

	local limits = config.Limits
	if type(limits) ~= "table" then
		return false, "Limits must be a table"
	end
	for _, field in { "BurstPerPlayer", "RefillPerSecond" } do
		if not isNumber(limits[field]) then
			return false, `Limits.{field} must be a number`
		end
		if limits[field] <= 0 then
			return false, `Limits.{field} must be above 0`
		end
	end
	return true, nil
end

return ConfigCheck
