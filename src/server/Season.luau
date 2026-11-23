--!strict
-- Season key transitions. Pure: each takes the stored value and returns a new table, never
-- changing its input, so they are safe inside UpdateAsync (which may run a transform twice).
-- A season ends only by a stored close; the clock says which season a server believes is current
-- and whether a close may be attempted, never that a season is over.
local Season = {}

export type Entry = { userId: number, score: number }
export type Season = {
	id: number,
	startsAt: number,
	endsAt: number,
	state: "open" | "closed",
	podium: { Entry },
	closedBy: string?,
	closedAt: number?,
}

local function isWhole(v: any): boolean
	return type(v) == "number" and v % 1 == 0
end

function Season.key(id: number): string
	return `season/{id}`
end

function Season.idAt(epoch: number, length: number, now: number): number?
	if length <= 0 or now < epoch then
		return nil
	end
	return math.floor((now - epoch) / length) + 1
end

function Season.window(epoch: number, length: number, id: number): (number, number)
	local startsAt = epoch + (id - 1) * length
	return startsAt, startsAt + length
end

-- Whether a stored season holds the window the config gives its id. False for a key made under
-- another SeasonLengthSeconds or Epoch, whose id then means a different span of time.
function Season.matches(stored: any, startsAt: number, endsAt: number): boolean
	return type(stored) == "table" and stored.startsAt == startsAt and stored.endsAt == endsAt
end

-- Creates the key if it is missing. An existing key, open or closed, is left alone.
function Season.open(current: Season?, id: number, startsAt: number, endsAt: number): (Season?, string?)
	if current ~= nil then
		return nil, "exists"
	end
	if not isWhole(id) or id < 1 or not isWhole(startsAt) or not isWhole(endsAt) or endsAt <= startsAt then
		return nil, "bad_season"
	end
	return { id = id, startsAt = startsAt, endsAt = endsAt, state = "open", podium = {} }, nil
end

-- Closes an open season whose end has passed. Running it on its own output refuses not_open, so
-- the first close wins and every later closer reads the stored podium.
function Season.close(current: Season?, now: number, podium: { Entry }, serverId: string): (Season?, string?)
	if current == nil then
		return nil, "missing"
	end
	if current.state ~= "open" then
		return nil, "not_open"
	end
	if now < current.endsAt then
		return nil, "not_ended"
	end
	local frozen: { Entry } = {}
	for _, entry in podium do
		table.insert(frozen, { userId = entry.userId, score = entry.score })
	end
	return {
		id = current.id,
		startsAt = current.startsAt,
		endsAt = current.endsAt,
		state = "closed",
		podium = frozen,
		closedBy = serverId,
		closedAt = now,
	},
		nil
end

return Season
