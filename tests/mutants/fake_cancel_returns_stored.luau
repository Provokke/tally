--!strict
-- FakeDataStore: nil mode returns the stored value, so no spec exercises a cancel that answers nil.
return {
	name = "fake_cancel_returns_stored",
	file = "tests/fakes/FakeDataStore.luau",
	find = [==[if self.cancelReturnsNil then]==],
	replace = [==[if false then]==],
}
