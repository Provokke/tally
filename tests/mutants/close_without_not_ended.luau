--!strict
-- Season.close: a server whose clock is behind can close early.
return {
	name = "close_without_not_ended",
	file = "src/server/Season.luau",
	find = "if now < current.endsAt then",
	replace = "if false then",
}
