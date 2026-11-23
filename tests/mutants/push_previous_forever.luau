--!strict
-- Tally.push: the previous season is pushed after its close and the grace, on every server forever.
return {
	name = "push_previous_forever",
	file = "src/server/Tally.luau",
	find = [==[known ~= nil
		and known.state == "closed"
		and deps.now() >= known.endsAt + deps.config.CloseGraceSeconds]==],
	replace = [==[false]==],
}
