--!strict
-- The fake is what every store test stands on, so its UpdateAsync behaviour is checked here.
local FakeClock = require("../fakes/FakeClock")
local FakeDataStore = require("../fakes/FakeDataStore")
local Faults = require("../fakes/Faults")

return {
	{
		name = "a forced re-run runs the transform twice on fresh copies and keeps the second result",
		run = function()
			local ds = FakeDataStore.new({ k = { n = 1 } })
			local seen: { number } = {}
			ds:rerunNext(1)
			ds:UpdateAsync("k", function(stored: any)
				table.insert(seen, stored.n)
				stored.n += 10 -- mutating the copy must not leak into the next run
				return { n = #seen * 100 }
			end)
			assert(#seen == 2 and seen[1] == 1 and seen[2] == 1, "both runs see the stored value")
			assert(ds.records.k.n == 200, "the last run is the one committed")
			-- control: without the re-run the transform runs once
			ds:UpdateAsync("k", function(stored: any)
				return { n = stored.n + 1 }
			end)
			assert(ds.runs == 3 and ds.records.k.n == 201)
		end,
	},
	{
		name = "a write between the read and the write makes the transform run again on the new value",
		run = function()
			local records = {}
			local ds = FakeDataStore.new(records)
			local other = FakeDataStore.new(records) -- a second server on the same store
			ds:hookNext(function()
				other:UpdateAsync("k", function()
					return { n = 5 }
				end)
			end)
			ds:UpdateAsync("k", function(stored: any)
				return { n = (if stored then stored.n else 0) + 1 }
			end)
			assert(records.k.n == 6, `expected the re-run to build on 5, got {records.k.n}`)
			assert(ds.runs == 2, "the first run was thrown away")
		end,
	},
	{
		name = "commit-then-fail writes the result and still throws",
		run = function()
			local ds = FakeDataStore.new({})
			ds:commitThenFailNext(1, "timed out")
			local ok = pcall(function()
				ds:UpdateAsync("k", function()
					return { n = 1 }
				end)
			end)
			assert(ok == false, "the call throws")
			assert(ds.records.k ~= nil and ds.records.k.n == 1, "but the write landed")
			-- control: failNext throws before writing anything
			ds:failNext(1, "throttled")
			pcall(function()
				ds:UpdateAsync("j", function()
					return { n = 1 }
				end)
			end)
			assert(ds.records.j == nil)
		end,
	},
	{
		name = "a nil result cancels the write even when the record changed meanwhile",
		run = function()
			local records = { k = { n = 1 } }
			local ds = FakeDataStore.new(records)
			local other = FakeDataStore.new(records)
			ds:hookNext(function()
				other:UpdateAsync("k", function()
					return { n = 2 }
				end)
			end)
			ds:UpdateAsync("k", function()
				return nil
			end)
			assert(records.k.n == 2 and ds.runs == 1, "cancelled at once, the other write stands")
		end,
	},
	{
		name = "a cancelled update returns the stored value, or nil when the store is set to answer a cancel with nil",
		run = function()
			local ds = FakeDataStore.new({ k = { n = 1 } })
			local cancelled = ds:UpdateAsync("k", function()
				return nil
			end)
			assert(cancelled ~= nil and cancelled.n == 1, "by default a cancel returns what is stored")
			ds.cancelReturnsNil = true
			local nothing = ds:UpdateAsync("k", function()
				return nil
			end)
			assert(nothing == nil, "in nil mode a cancel returns nil")
			assert(ds.records.k.n == 1, "and writes nothing")
			local written = ds:UpdateAsync("k", function()
				return { n = 2 }
			end)
			assert(
				written ~= nil and written.n == 2 and ds.records.k.n == 2,
				"a write still returns its value"
			)
		end,
	},
	{
		name = "a handle with a read cache serves the cached value unless the read asks for UseCache = false",
		run = function()
			local clock = FakeClock.new(0)
			local ds = FakeDataStore.new({ k = { n = 1 } })
			local handle = ds:handle(Faults.new(), { cacheSeconds = 60, clock = clock })
			assert(handle:GetAsync("k").n == 1)
			ds.records.k = { n = 2 }
			assert(handle:GetAsync("k").n == 1, "cached")
			assert(handle:GetAsync("k", { UseCache = false }).n == 2, "an uncached read sees the store")
			assert(
				#ds.gets == 3 and not ds.gets[2].uncached and ds.gets[3].uncached,
				"and each read is recorded"
			)
		end,
	},
	{
		name = "a lost write does not refresh the read cache: the client never saw the response",
		run = function()
			local clock = FakeClock.new(1000)
			local ds = FakeDataStore.new()
			local faults = Faults.new()
			local h = ds:handle(faults, { cacheSeconds = 4, clock = clock })
			h:UpdateAsync("a", function()
				return { n = 1 }
			end)
			assert(h:GetAsync("a").n == 1)
			faults:arm(1, "lost")
			pcall(function()
				h:UpdateAsync("a", function()
					return { n = 2 }
				end)
			end)
			assert(ds.records.a.n == 2, "the lost write landed")
			assert(h:GetAsync("a").n == 1, "the cache must still hold what the client last saw")
			clock:advance(5)
			assert(h:GetAsync("a").n == 2)
			h:UpdateAsync("a", function()
				return { n = 3 }
			end)
			assert(h:GetAsync("a").n == 3, "a write that returns refreshes the cache")
		end,
	},
	{
		name = "a value a real DataStore could not hold is refused, naming where, and the record is unchanged",
		run = function()
			local function write(ds: any, value: any): (boolean, string)
				local ok, err = pcall(function()
					ds:UpdateAsync("k", function()
						return value
					end)
				end)
				return ok, tostring(err)
			end
			local ds = FakeDataStore.new({ k = { keep = true } })
			local ok = write(ds, {
				coins = 5,
				lifetime = {},
				seasons = { ["3"] = { score = 1, rewarded = false } },
				streak = { day = 0, count = 0, earned = 0 },
				notices = { { text = "a", at = 1 } },
			})
			assert(ok, "a profile-shaped table is stored")
			assert(write(ds, { 1, 2, 3 }), "a plain array is stored")
			ds.records.k = { keep = true }

			local sparse, err = write(ds, { seasons = { [3] = {} } })
			assert(not sparse and string.find(err, "seasons", 1, true), err)
			assert(string.find(err, "not storable", 1, true), err)
			local gap, gapErr = write(ds, { [1] = 1, [3] = 3 })
			assert(not gap and string.find(gapErr, "not storable", 1, true), gapErr)
			local mixedTable: any = { 1 }
			mixedTable.name = "x"
			local mixed = write(ds, mixedTable)
			assert(not mixed, "string and number keys mixed")
			local nan = write(ds, { n = 0 / 0 })
			assert(not nan, "NaN")
			local inf = write(ds, { n = math.huge })
			assert(not inf, "infinity")
			local fn = write(ds, { f = function() end })
			assert(not fn, "a function")
			local cyclic: any = {}
			cyclic.self = cyclic
			assert(not write(ds, cyclic), "a cycle")
			assert(not write(ds, { [true] = 1 }), "a boolean key")
			assert(ds.records.k.keep == true and ds.records.k.coins == nil, "refused writes leave the record")
		end,
	},
	{
		name = "with events set, a GetAsync and an UpdateAsync on one key leave get then call",
		run = function()
			local ds = FakeDataStore.new({ k = { n = 1 } })
			ds.events = {}
			local h = ds:handle(Faults.new())
			assert(h:GetAsync("k").n == 1)
			h:UpdateAsync("k", function(stored: any)
				return stored
			end)
			assert(
				#ds.events == 2 and ds.events[1] == "get k" and ds.events[2] == "call k",
				table.concat(ds.events, ",")
			)
			ds.events = nil
			h:GetAsync("k") -- control: no events table, nothing recorded and nothing thrown
		end,
	},
}
