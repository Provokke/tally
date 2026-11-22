--!strict
-- Scores.record: a score still counts after the player was paid.
return {
	name = "record_after_rewarded",
	file = "src/server/Scores.luau",
	find = "if entry ~= nil and entry.rewarded then",
	replace = "if false then",
}
