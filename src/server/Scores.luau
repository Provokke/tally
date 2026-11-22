--!strict
-- Score recording. Pure rules over a profile table: no clock, no store. A game's own server code
-- decides what a point is worth and calls Tally:record, which calls this. There is no remote that
-- accepts points.
local Scores = {}

export type Rules = { mode: "sum" | "best", maxPoints: number, stat: string }
export type SeasonView = { endsAt: number, state: string }

local function isPoints(v: any, max: number): boolean
	return type(v) == "number" and v % 1 == 0 and v >= 1 and v <= max
end

-- Season ids are string keys: a stored table can't be keyed by a sparse number.
function Scores.key(seasonId: number): string
	return tostring(seasonId)
end

function Scores.score(profile: any, seasonId: number): number
	local entry = profile.seasons[Scores.key(seasonId)]
	if entry == nil then
		return 0
	end
	return entry.score
end

-- Raises the season score and the lifetime total, or refuses and changes nothing.
function Scores.record(
	profile: any,
	seasonId: number,
	points: any,
	season: SeasonView,
	now: number,
	rules: Rules
): (boolean, string?)
	if not isPoints(points, rules.maxPoints) then
		return false, "bad_points"
	end
	if now >= season.endsAt then
		return false, "season_ended"
	end
	local key = Scores.key(seasonId)
	local entry = profile.seasons[key]
	if entry ~= nil and entry.rewarded then
		return false, "already_rewarded"
	end
	if season.state == "closed" then
		return false, "closed"
	end
	if entry == nil then
		entry = { score = 0, rewarded = false }
		profile.seasons[key] = entry
	end
	if rules.mode == "best" then
		entry.score = math.max(entry.score, points)
	else
		entry.score += points
	end
	profile.lifetime[rules.stat] = (profile.lifetime[rules.stat] or 0) + points
	return true, nil
end

return Scores
