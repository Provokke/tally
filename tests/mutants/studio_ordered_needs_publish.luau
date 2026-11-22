--!strict
-- Server script: Studio always uses the real stores, so an unpublished place can't start.
return {
	name = "studio_ordered_needs_publish",
	file = "src/server/init.server.luau",
	find = [==[local useRealStore = not RunService:IsStudio() or ServerStorage:GetAttribute("TallyUseDataStore") == true]==],
	replace = "local useRealStore = true",
}
