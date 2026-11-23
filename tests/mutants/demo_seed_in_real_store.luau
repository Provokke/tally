--!strict
-- Server script: the demo seed ignores which store is in use, so it would write into a real data store.
return {
	name = "demo_seed_in_real_store",
	file = "src/server/init.server.luau",
	find = "\t\tuseRealStore\n\t\tor not RunService:IsStudio()",
	replace = "\t\tnot RunService:IsStudio()",
}
