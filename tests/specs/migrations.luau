--!strict
local Deep = require("../fakes/Deep")
local Migrations = require("../../src/server/Data/Migrations")

local steps = {
	function(data: any)
		data.pieces = {}
		return data
	end,
	function(data: any)
		data.lifetime = data.pieces
		data.pieces = nil
		return data
	end,
}

return {
	{
		name = "v1 to v3 runs both steps in order",
		run = function()
			local data, readOnly =
				Migrations.run({ schema = 1, data = { name = "x" }, savedAt = 0 }, steps, 3)
			assert(readOnly == false)
			assert(type(data.lifetime) == "table", "lifetime should be there")
			assert(data.pieces == nil, "pieces should be renamed away")
			assert(data.name == "x")
		end,
	},
	{
		name = "a record already at current is unchanged",
		run = function()
			local data, readOnly = Migrations.run({ schema = 3, data = { coins = 5 }, savedAt = 0 }, steps, 3)
			assert(readOnly == false)
			assert(Deep.equal(data, { coins = 5 }), "data should be untouched")
		end,
	},
	{
		name = "a record from the future comes back read-only with data untouched",
		run = function()
			local data, readOnly =
				Migrations.run({ schema = 5, data = { future = true }, savedAt = 0 }, steps, 3)
			assert(readOnly == true)
			assert(Deep.equal(data, { future = true }))
		end,
	},
	{
		name = "migrating does not mutate the input record",
		run = function()
			local record = { schema = 1, data = { name = "x" }, savedAt = 0 }
			local snapshot = Deep.copy(record)
			local data = Migrations.run(record, steps, 3)
			assert(type(data.lifetime) == "table", "the migration did run")
			assert(Deep.equal(record, snapshot), "input record changed")
		end,
	},
	{
		name = "a missing step raises an error that names the schema",
		run = function()
			local ok, err = pcall(function()
				Migrations.run({ schema = 1, data = {}, savedAt = 0 }, {}, 3)
			end)
			assert(not ok and string.find(tostring(err), "schema 1", 1, true), tostring(err))
			-- control
			local data = Migrations.run({ schema = 1, data = {}, savedAt = 0 }, {
				function(d: any)
					d.a = 1
					return d
				end,
				function(d: any)
					d.b = 2
					return d
				end,
			}, 3)
			assert(data.a == 1 and data.b == 2)
		end,
	},
}
