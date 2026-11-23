--!strict
-- init.server: the options handed to Tally allow the cache.
return {
	name = "server_reads_cached",
	file = "src/server/init.server.luau",
	find = [==[uncachedRead.UseCache = false]==],
	replace = [==[uncachedRead.UseCache = true]==],
}
