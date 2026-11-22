--!strict
-- Lease: a foreign lease never runs out.
return {
	name = "lease_never_expires",
	file = "src/server/Data/Lease.luau",
	find = "if theirs.expiresAt > now then",
	replace = "if true then",
}
