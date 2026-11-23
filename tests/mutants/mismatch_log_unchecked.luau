--!strict
-- accept: the mismatch log indexes the stored value without checking it is a table.
return {
	name = "mismatch_log_unchecked",
	file = "src/server/Tally.luau",
	find = [==[		return `{typeof(stored)} {tostring(stored)}`
	end
	return]==],
	replace = [==[		return `{stored.startsAt}`
	end
	return]==],
}
