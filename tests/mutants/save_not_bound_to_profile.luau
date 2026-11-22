--!strict
-- Server script: a save writes the player's live session even when the caller changed a dead one.
return {
	name = "save_not_bound_to_profile",
	file = "src/server/init.server.luau",
	find = [==[if session == nil or session.data ~= staked then]==],
	replace = [==[if session == nil then]==],
}
