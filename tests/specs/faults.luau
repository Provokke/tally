--!strict
local FakeDataStore = require("../fakes/FakeDataStore")
local Faults = require("../fakes/Faults")

local function put(n: number): (any) -> any
	return function()
		return { n = n }
	end
end

local function raised(fn: () -> ()): string
	local ok, err = pcall(fn)
	assert(not ok, "expected the call to raise")
	return tostring(err)
end

return {
	{
		name = "a stop armed at write 2 lets write 1 land, refuses write 2 unapplied and kills every later call",
		run = function()
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults)
			faults:arm(2, "stop")
			h:UpdateAsync("a", put(1))
			assert(ds.records.a.n == 1 and faults.writes == 1 and not faults.dead)
			assert(string.find(
				raised(function()
					h:UpdateAsync("b", put(2))
				end),
				"CRASH",
				1,
				true
			))
			assert(ds.records.b == nil, "the stopped write must not be applied")
			assert(ds.calls == 1, "the store never saw the stopped call")
			assert(faults.dead and faults.writes == 2)
			assert(string.find(
				raised(function()
					h:UpdateAsync("c", put(3))
				end),
				"CRASH",
				1,
				true
			))
			assert(
				string.find(
					raised(function()
						h:GetAsync("a")
					end),
					"CRASH",
					1,
					true
				),
				"reads of a dead server raise too"
			)
			assert(ds.records.c == nil)
		end,
	},
	{
		name = "k counts from the arm call, not from the start",
		run = function()
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults)
			h:UpdateAsync("a", put(1))
			h:UpdateAsync("b", put(2))
			faults:arm(1, "stop")
			raised(function()
				h:UpdateAsync("c", put(3))
			end)
			assert(ds.records.c == nil and ds.records.b.n == 2)
		end,
	},
	{
		name = "a read does not count as a write",
		run = function()
			local ds = FakeDataStore.new({ a = { n = 1 } })
			local faults = Faults.new()
			local h = ds:handle(faults)
			faults:arm(1, "stop")
			assert(h:GetAsync("a").n == 1)
			assert(faults.writes == 0 and not faults.dead, "the read must leave the armed write alone")
			raised(function()
				h:UpdateAsync("a", put(2))
			end)
			assert(ds.records.a.n == 1)
		end,
	},
	{
		name = "a lost armed at write 1 applies the write, raises, and the next write works",
		run = function()
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults)
			faults:arm(1, "lost")
			assert(string.find(
				raised(function()
					h:UpdateAsync("a", put(1))
				end),
				"lost response",
				1,
				true
			))
			assert(ds.records.a.n == 1, "a lost response still applied the write")
			assert(not faults.dead)
			h:UpdateAsync("b", put(2))
			assert(ds.records.b.n == 2 and faults.writes == 2)
			assert(h:GetAsync("a").n == 1)
		end,
	},
	{
		name = "an armed write fires once: writes after a lost run normally",
		run = function()
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults)
			faults:arm(1, "lost")
			raised(function()
				h:UpdateAsync("a", put(1))
			end)
			h:UpdateAsync("a", put(2))
			h:UpdateAsync("a", put(3))
			assert(ds.records.a.n == 3)
		end,
	},
	{
		name = "two handles with separate Faults: killing one leaves the other working on the same records",
		run = function()
			local ds = FakeDataStore.new()
			local f1, f2 = Faults.new(), Faults.new()
			local h1, h2 = ds:handle(f1), ds:handle(f2)
			h1:UpdateAsync("a", put(1))
			f1:arm(1, "stop")
			raised(function()
				h1:UpdateAsync("a", put(99))
			end)
			assert(f1.dead and not f2.dead)
			assert(h2:GetAsync("a").n == 1, "the other server sees the first write")
			h2:UpdateAsync("b", put(2))
			assert(ds.records.b.n == 2 and ds.records.a.n == 1)
			assert(f2.writes == 1 and f1.writes == 2, "each server counts its own writes")
		end,
	},
	{
		name = "a fail armed at write 2 raises before applying it, leaves the server alive, and fires once",
		run = function()
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults)
			faults:arm(2, "fail")
			h:UpdateAsync("a", put(1))
			assert(string.find(
				raised(function()
					h:UpdateAsync("b", put(2))
				end),
				"request failed",
				1,
				true
			))
			assert(ds.records.b == nil, "a failed request never reached the store")
			assert(not faults.dead and faults.target == nil)
			h:UpdateAsync("b", put(3))
			assert(ds.records.b.n == 3 and faults.writes == 3)
		end,
	},
	{
		name = "armPair loses two writes: both land, both raise, the server carries on",
		run = function()
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults)
			faults:armPair(1, 3)
			for i, key in { "a", "b", "c", "d" } do
				local ok = pcall(function()
					h:UpdateAsync(key, put(i))
				end)
				assert(ok == (i == 2 or i == 4), `write {i} raised wrongly`)
			end
			assert(ds.records.a.n == 1 and ds.records.c.n == 3, "a lost write still lands")
			assert(not faults.dead and next(faults.also) == nil)
		end,
	},
}
