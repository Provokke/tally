--!strict
-- The shape of one player's saved data, and how the session form is turned into the stored form
-- and back.
--
--   coins     number                       the player's wallet
--   lifetime  { [stat]: number }           running totals the kit keeps, such as points
--   seasons   { [seasonId]: SeasonEntry }  one entry per season played, keyed by the id as a string
--   streak    { day, count, earned }       the daily streak: last day claimed, run length, Coins earned
--   notices   { { text, at } }             what happened while they were away, oldest first
--
-- A new profile (schema 1) is made from the starting coins, and the claim that creates the record
-- writes them, so they are never granted twice. encode and decode copy every field, so a field
-- added to defaultData is saved and loaded without being listed here.
local Profile = {}

type Data = { [string]: any }

export type Deps = {
	startingCoins: number, -- what a new player starts with
}

export type Profile = {
	defaultData: () -> Data,
	encode: (data: Data) -> Data,
	decode: (saved: Data) -> Data,
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[deepCopy(k)] = deepCopy(v)
	end
	return out
end

local function defaultStreak(): Data
	return { day = 0, count = 0, earned = 0 }
end

function Profile.new(deps: Deps): Profile
	local function defaultData(): Data
		return {
			coins = deps.startingCoins,
			lifetime = {},
			seasons = {},
			streak = defaultStreak(),
			notices = {},
		}
	end

	-- Session form to stored form. Runs inside UpdateAsync transforms, so it must not yield.
	local function encode(data: Data): Data
		return deepCopy(data)
	end

	-- Stored form to session form. Data that isn't a table, or that has no coin balance, is
	-- refused, so the load fails and the record is left alone instead of being opened as an
	-- empty profile (which would hand out the starting coins again). A missing lifetime, seasons
	-- or notices table is made empty, and a missing or malformed streak is made the default.
	local function decode(saved: Data): Data
		if type(saved) ~= "table" then
			error("saved data is not a table")
		end
		if type(saved.coins) ~= "number" then
			error("saved data has no coins")
		end
		local out = deepCopy(saved)
		for _, field in { "lifetime", "seasons", "notices" } do
			if type(out[field]) ~= "table" then
				out[field] = {}
			end
		end
		local streak = out.streak
		if
			type(streak) ~= "table"
			or type(streak.day) ~= "number"
			or type(streak.count) ~= "number"
			or type(streak.earned) ~= "number"
		then
			out.streak = defaultStreak()
		end
		return out
	end

	return { defaultData = defaultData, encode = encode, decode = decode }
end

return Profile
