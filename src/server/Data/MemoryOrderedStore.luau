--!strict
-- Studio stand-in for an OrderedDataStore. An unpublished place can't reach the real one, so Studio
-- uses this unless ServerStorage TallyUseDataStore is true. Values live and die with the server.
local MemoryOrderedStore = {}
MemoryOrderedStore.__index = MemoryOrderedStore

type Row = { key: string, value: number }

export type MemoryOrderedStore = typeof(setmetatable(
	{} :: { values: { [string]: number } },
	MemoryOrderedStore
))

local function isWhole(v: any): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and math.abs(v) < 2 ^ 53
end

local function sortRows(rows: { Row }, ascending: boolean)
	table.sort(rows, function(a: Row, b: Row): boolean
		if a.value ~= b.value then
			if ascending then
				return a.value < b.value
			end
			return a.value > b.value
		end
		return a.key < b.key
	end)
end

-- The shape of a real DataStorePages, over a snapshot of the rows.
local function pagesOf(rows: { Row }, pageSize: number): any
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

function MemoryOrderedStore.new(): MemoryOrderedStore
	return setmetatable({ values = {} }, MemoryOrderedStore)
end

function MemoryOrderedStore.SetAsync(self: MemoryOrderedStore, key: string, value: number)
	assert(type(key) == "string" and #key > 0, "an ordered store key is a non-empty string")
	assert(isWhole(value), "an ordered store value is a whole number")
	self.values[key] = value
end

function MemoryOrderedStore.UpdateAsync(
	self: MemoryOrderedStore,
	key: string,
	transform: (number?) -> number?
): number?
	local current = self.values[key]
	local result = transform(current)
	if result == nil then
		return current
	end
	self:SetAsync(key, result)
	return result
end

function MemoryOrderedStore.GetAsync(self: MemoryOrderedStore, key: string): number?
	return self.values[key]
end

function MemoryOrderedStore.GetSortedAsync(
	self: MemoryOrderedStore,
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
	for key, value in self.values do
		if (min == nil or value >= min) and (max == nil or value <= max) then
			table.insert(rows, { key = key, value = value })
		end
	end
	sortRows(rows, ascending)
	return pagesOf(rows, pageSize)
end

return MemoryOrderedStore
