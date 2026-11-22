--!strict
-- FakeOrderedDataStore: a write is visible to ranks at once, so no spec can see a stale rank.
return {
	name = "ordered_lag_ignored",
	file = "tests/fakes/FakeOrderedDataStore.luau",
	find = "if version.visibleAt <= now then",
	replace = "if true then",
}
