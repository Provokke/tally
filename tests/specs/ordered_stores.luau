--!strict
local FakeClock = require("../fakes/FakeClock")
local FakeOrderedDataStore = require("../fakes/FakeOrderedDataStore")
local Faults = require("../fakes/Faults")
local MemoryOrderedStore = require("../../src/server/Data/MemoryOrderedStore")

local makers: { [string]: () -> any } = {
	fake = function()
		return FakeOrderedDataStore.new(FakeClock.new(1000), 0):handle(Faults.new())
	end,
	memory = function()
		return MemoryOrderedStore.new()
	end,
}

local function keysOf(page: { { key: string, value: number } }): string
	local out = {}
	for _, row in page do
		table.insert(out, `{row.key}={row.value}`)
	end
	return table.concat(out, ",")
end

local function raises(fn: () -> ()): string?
	local ok, err = pcall(fn)
	if ok then
		return nil
	end
	return tostring(err)
end

local cases = {}

for name, make in makers do
	table.insert(cases, {
		name = `{name}: SetAsync then GetAsync returns the value, a missing key returns nil`,
		run = function()
			local store = make()
			store:SetAsync("101", 7)
			assert(store:GetAsync("101") == 7)
			assert(store:GetAsync("nope") == nil)
		end,
	})
	table.insert(cases, {
		name = `{name}: GetSortedAsync orders by value, ties by key ascending`,
		run = function()
			local store = make()
			store:SetAsync("102", 5)
			store:SetAsync("101", 5)
			store:SetAsync("103", 9)
			store:SetAsync("104", 1)
			local down = keysOf(store:GetSortedAsync(false, 10):GetCurrentPage())
			assert(down == "103=9,101=5,102=5,104=1", down)
			local up = keysOf(store:GetSortedAsync(true, 10):GetCurrentPage())
			assert(up == "104=1,101=5,102=5,103=9", up)
		end,
	})
	table.insert(cases, {
		name = `{name}: pages split by pageSize and advance until finished`,
		run = function()
			local store = make()
			for i = 1, 5 do
				store:SetAsync(tostring(100 + i), i)
			end
			local pages = store:GetSortedAsync(false, 2)
			assert(#pages:GetCurrentPage() == 2 and pages.IsFinished == false)
			pages:AdvanceToNextPageAsync()
			assert(#pages:GetCurrentPage() == 2 and pages.IsFinished == false)
			pages:AdvanceToNextPageAsync()
			assert(#pages:GetCurrentPage() == 1 and pages.IsFinished == true)
		end,
	})
	table.insert(cases, {
		name = `{name}: min and max are inclusive`,
		run = function()
			local store = make()
			for i = 1, 5 do
				store:SetAsync(tostring(100 + i), i)
			end
			local page = store:GetSortedAsync(false, 10, 2, 4):GetCurrentPage()
			assert(keysOf(page) == "104=4,103=3,102=2", keysOf(page))
		end,
	})
	table.insert(cases, {
		name = `{name}: SetAsync refuses a fraction, a string and NaN, and writes nothing`,
		run = function()
			local store = make()
			for _, bad in { 1.5, "5", 0 / 0 } do
				assert(raises(function()
					store:SetAsync("101", bad)
				end) ~= nil, "should raise")
			end
			assert(store:GetAsync("101") == nil)
			assert(#store:GetSortedAsync(false, 10):GetCurrentPage() == 0)
		end,
	})
	table.insert(cases, {
		name = `{name}: UpdateAsync adds, a nil transform cancels, an empty key gives nil`,
		run = function()
			local store = make()
			local seen: any = "unset"
			store:UpdateAsync("101", function(current: any)
				seen = current
				return 3
			end)
			assert(seen == nil and store:GetAsync("101") == 3)
			local result = store:UpdateAsync("101", function(current: any)
				return current + 4
			end)
			assert(result == 7 and store:GetAsync("101") == 7)
			local cancelled = store:UpdateAsync("101", function()
				return nil
			end)
			assert(cancelled == 7 and store:GetAsync("101") == 7)
		end,
	})
	table.insert(cases, {
		name = `{name}: a page is a snapshot`,
		run = function()
			local store = make()
			store:SetAsync("101", 1)
			local pages = store:GetSortedAsync(false, 10)
			store:SetAsync("102", 2)
			store:SetAsync("101", 9)
			assert(keysOf(pages:GetCurrentPage()) == "101=1")
		end,
	})
end

local function fakeWith(lag: number): (any, any, any)
	local clock = FakeClock.new(1000)
	local store = FakeOrderedDataStore.new(clock, lag)
	return store, store:handle(Faults.new()), clock
end

table.insert(cases, {
	name = "fake: with lag a write reaches ranks only after the lag, and a second write waits its own lag",
	run = function()
		local _, handle, clock = fakeWith(30)
		handle:SetAsync("101", 5)
		assert(handle:GetAsync("101") == 5)
		assert(#handle:GetSortedAsync(false, 10):GetCurrentPage() == 0)
		clock:advance(20)
		handle:SetAsync("101", 8)
		clock:advance(10)
		assert(keysOf(handle:GetSortedAsync(false, 10):GetCurrentPage()) == "101=5")
		assert(handle:GetAsync("101") == 8)
		clock:advance(19)
		assert(keysOf(handle:GetSortedAsync(false, 10):GetCurrentPage()) == "101=5")
		clock:advance(1)
		assert(keysOf(handle:GetSortedAsync(false, 10):GetCurrentPage()) == "101=8")
	end,
})

table.insert(cases, {
	name = "fake: with lag 0 a write is visible to ranks at once",
	run = function()
		local _, handle = fakeWith(0)
		handle:SetAsync("101", 5)
		assert(keysOf(handle:GetSortedAsync(false, 10):GetCurrentPage()) == "101=5")
	end,
})

table.insert(cases, {
	name = "fake: sortedReads counts sorted reads only",
	run = function()
		local store, handle = fakeWith(0)
		handle:SetAsync("101", 5)
		handle:GetAsync("101")
		assert(store.sortedReads == 0)
		handle:GetSortedAsync(false, 10)
		handle:GetSortedAsync(true, 10)
		assert(store.sortedReads == 2)
	end,
})

table.insert(cases, {
	name = "fake: faults stop, lost and fail behave as on the data store handle",
	run = function()
		local store = FakeOrderedDataStore.new(FakeClock.new(1000), 0)

		local stopFaults = Faults.new()
		local stopped = store:handle(stopFaults)
		stopFaults:arm(1, "stop")
		local stopErr = raises(function()
			stopped:SetAsync("101", 1)
		end)
		assert(stopErr ~= nil and string.find(stopErr, "CRASH", 1, true) ~= nil, "an armed stop raises CRASH")
		assert(store.current["101"] == nil, "a stopped write is not applied")
		for _, call in
			{
				function()
					stopped:GetAsync("101")
				end,
				function()
					stopped:GetSortedAsync(false, 10)
				end,
				function()
					stopped:SetAsync("102", 1)
				end,
			}
		do
			local err = raises(call)
			assert(err ~= nil and string.find(err, "CRASH", 1, true) ~= nil, "a dead server raises CRASH")
		end

		local lostFaults = Faults.new()
		local lost = store:handle(lostFaults)
		lostFaults:arm(1, "lost")
		local lostErr = raises(function()
			lost:SetAsync("103", 3)
		end)
		assert(lostErr ~= nil and string.find(lostErr, "lost response", 1, true) ~= nil)
		assert(store.current["103"] == 3, "a lost response still lands the write")

		local failFaults = Faults.new()
		local failing = store:handle(failFaults)
		failFaults:arm(1, "fail")
		assert(raises(function()
			failing:SetAsync("104", 4)
		end) ~= nil)
		assert(store.current["104"] == nil, "a failed write leaves nothing")
		assert(failing:GetAsync("103") == 3 and failFaults.dead == false, "the server carries on")
	end,
})

return cases
