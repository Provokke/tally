--!strict
-- Tally.push: a closed previous season is dropped at once, not after the grace.
return {
	name = "push_previous_stops_at_close",
	file = "src/server/Tally.luau",
	find = [==[deps.now() >= known.endsAt + deps.config.CloseGraceSeconds]==],
	replace = [==[true]==],
}
