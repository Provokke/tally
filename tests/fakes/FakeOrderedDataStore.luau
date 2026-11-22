--!strict
-- In-memory stand-in for an OrderedDataStore with the one behaviour the kit has to survive:
-- ranks are eventually consistent. A write is visible to GetAsync at once and to sorted reads
-- only after `lag` seconds.
local Faults = require("./Faults")

local FakeOrderedDataStore = {}
FakeOrderedDataStore.__index = FakeOrderedDataStore

type Version = { value: number, visibleAt: number }
type Row = { key: string, value: number }

export type FakeOrderedDataStore = typeof(setmetatable(
	{} :: {
		clock: any,
		lag: number,
		current: { [string]: number },
		history: { [string]: { Version } },
		sortedReads: number,
	},
	FakeOrderedDataStore
))

function FakeOrderedDataStore.new(clock: any, lag: number?): FakeOrderedDataStore
	return setmetatable(
		{ clock = clock, lag = lag or 0, current = {}, history = {}, sortedReads = 0 },
		FakeOrderedDataStore
	)
end

local function isWhole(v: any): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 53
end

function FakeOrderedDataStore.write(self: FakeOrderedDataStore, key: string, value: any)
	assert(type(key) == "string" and #key > 0, "an ordered store key is a non-empty string")
	assert(isWhole(value), "an ordered store value is a whole number")
	self.current[key] = value
	local versions = self.history[key] or {}
	self.history[key] = versions
	table.insert(versions, { value = value, visibleAt = self.clock:now() + self.lag })
end

-- What a sorted read sees at this moment: the latest version of each key that has aged past the lag.
local function visible(self: FakeOrderedDataStore): { Row }
	local now = self.clock:now()
	local rows = {}
	for key, versions in self.history do
		local seen: number? = nil
		for _, version in versions do
			if version.visibleAt <= now then
				seen = version.value
			end
		end
		if seen ~= nil then
			table.insert(rows, { key = key, value = seen })
		end
	end
	return rows
end

-- The shape of a real DataStorePages: IsFinished, GetCurrentPage and AdvanceToNextPageAsync, over
-- a snapshot taken when the sorted read was made.
local function sorted(
	self: FakeOrderedDataStore,
	ascending: boolean,
	pageSize: number,
	min: number?,
	max: number?
): any
	assert(
		isWhole(pageSize) and pageSize >= 1 and pageSize <= 100,
		"pageSize is a whole number from 1 to 100"
	)
	local rows: { Row } = {}
	for _, row in visible(self) do
		if (min == nil or row.value >= min) and (max == nil or row.value <= max) then
			table.insert(rows, row)
		end
	end
	table.sort(rows, function(a: Row, b: Row): boolean
		if a.value ~= b.value then
			if ascending then
				return a.value < b.value
			end
			return a.value > b.value
		end
		return a.key < b.key
	end)
	local pages: { { Row } } = {}
	for i, row in rows do
		local at = (i - 1) // pageSize + 1
		pages[at] = pages[at] or {}
		table.insert(pages[at], row)
	end
	if #pages == 0 then
		pages[1] = {}
	end
	local index = 1
	local result = {}
	result.IsFinished = index >= #pages
	function result.GetCurrentPage(_: any): { Row }
		return pages[index]
	end
	function result.AdvanceToNextPageAsync(_: any)
		assert(index < #pages, "there is no next page")
		index += 1
		result.IsFinished = index >= #pages
	end
	return result
end

export type Handle = {
	SetAsync: (self: Handle, key: string, value: number) -> (),
	UpdateAsync: (self: Handle, key: string, transform: (number?) -> number?) -> number?,
	GetAsync: (self: Handle, key: string) -> number?,
	GetSortedAsync: (self: Handle, ascending: boolean, pageSize: number, min: number?, max: number?) -> any,
}

-- One simulated server's view of this store. Every SetAsync and UpdateAsync counts as a write on
-- `faults` and every call raises CRASH once the server is dead.
function FakeOrderedDataStore.handle(self: FakeOrderedDataStore, faults: Faults.Faults): Handle
	local handle = {}
	function handle.SetAsync(_: any, key: string, value: number)
		local mode = faults:beforeWrite()
		self:write(key, value)
		if mode == "lost" then
			Faults.lose()
		end
	end
	function handle.UpdateAsync(_: any, key: string, transform: (number?) -> number?): number?
		local mode = faults:beforeWrite()
		local current = self.current[key]
		local result = transform(current)
		if result == nil then
			return current
		end
		self:write(key, result)
		if mode == "lost" then
			Faults.lose()
		end
		return result
	end
	function handle.GetAsync(_: any, key: string): number?
		faults:beforeRead()
		return self.current[key]
	end
	function handle.GetSortedAsync(
		_: any,
		ascending: boolean,
		pageSize: number,
		min: number?,
		max: number?
	): any
		faults:beforeRead()
		self.sortedReads += 1
		return sorted(self, ascending, pageSize, min, max)
	end
	return handle :: Handle
end

return FakeOrderedDataStore
