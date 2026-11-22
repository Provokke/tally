--!strict
-- Scores: in best mode the season score adds every submission instead of keeping the highest.
return {
	name = "best_mode_adds",
	file = "src/server/Scores.luau",
	find = "entry.score = math.max(entry.score, points)",
	replace = "entry.score += points",
}
