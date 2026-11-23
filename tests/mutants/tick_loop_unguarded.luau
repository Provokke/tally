--!strict
-- init.server: a season tick that raises ends the tick loop.
return {
	name = "tick_loop_unguarded",
	file = "src/server/init.server.luau",
	find = [==[		local ok, err = pcall(tally.tick, tally)
		if not ok then
			log(`tick failed: {tostring(err)}`)
		end]==],
	replace = [==[		tally:tick()]==],
}
