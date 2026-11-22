--!strict
local MemoryStore = require("../../src/server/Data/MemoryStore")

return {
	{
		name = "UpdateAsync stores a copy, so later edits to the original don't leak in",
		run = function()
			local store = MemoryStore.new()
			local value = { coins = 1, nested = { n = 1 } }
			store:UpdateAsync("k", function()
				return value
			end)
			value.coins = 99
			value.nested.n = 99
			local seen: any
			store:UpdateAsync("k", function(current: any)
				seen = current
				return nil
			end)
			assert(seen.coins == 1 and seen.nested.n == 1, "stored data should be unaffected")
		end,
	},
	{
		name = "a nil result cancels the write, a table result replaces the record",
		run = function()
			local store = MemoryStore.new()
			store:UpdateAsync("k", function()
				return nil
			end)
			assert(store.records.k == nil, "cancelled write stored nothing")
			store:UpdateAsync("k", function()
				return { v = 2 }
			end)
			assert(store.records.k.v == 2)
			store:UpdateAsync("k", function(current: any)
				return { v = current.v + 1 }
			end)
			assert(store.records.k.v == 3, "the transform sees the stored record")
		end,
	},
	{
		name = "GetAsync returns a copy of the stored value, or nil for a key never written",
		run = function()
			local store = MemoryStore.new()
			assert(store:GetAsync("missing") == nil)
			store:UpdateAsync("k", function()
				return { coins = 1, nested = { n = 1 } }
			end)
			local read = store:GetAsync("k", { UseCache = false })
			assert(read.coins == 1 and read.nested.n == 1)
			read.nested.n = 99
			assert(store:GetAsync("k").nested.n == 1, "editing the copy changes nothing")
		end,
	},
}
