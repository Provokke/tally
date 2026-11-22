--!strict
-- In-memory stand-in for a DataStore. Two instances built on the same `records` table behave
-- like two servers talking to one store.
--
-- It follows the parts of the UpdateAsync contract that the store's safety depends on:
-- - the transform gets a copy, and a copy of its result is stored (nil means cancel);
-- - if the record changed between the read and the write, the transform runs again on a fresh
--   copy, so a transform may run more than once and only the last run is committed;
-- - a call can fail before anything is written, or after the write has landed.
-- `hookNext` runs code between the read and the write (it may write the record itself, or
-- yield the calling thread), which is how tests interleave two calls.
local Deep = require("./Deep")
local Faults = require("./Faults")

local FakeDataStore = {}
FakeDataStore.__index = FakeDataStore

export type FakeDataStore = typeof(setmetatable(
	{} :: {
		records: { [string]: any },
		calls: number, -- UpdateAsync calls
		runs: number, -- transform runs, which can be more than calls
		failures: number,
		failMessage: string,
		commitFailures: number,
		commitMessage: string,
		reruns: number,
		hooks: { (key: string) -> () },
		events: { string }?, -- when set, "call <key>" is appended at the start of each call
	},
	FakeDataStore
))

function FakeDataStore.new(records: { [string]: any }?): FakeDataStore
	return setmetatable({
		records = records or {},
		calls = 0,
		runs = 0,
		failures = 0,
		failMessage = "",
		commitFailures = 0,
		commitMessage = "",
		reruns = 0,
		hooks = {},
		events = nil,
	}, FakeDataStore)
end

-- The next n calls throw before reading or writing anything.
function FakeDataStore.failNext(self: FakeDataStore, n: number, message: string)
	self.failures = n
	self.failMessage = message
end

-- The next n calls write their result and then throw, as a call that timed out after the
-- service had already committed it does.
function FakeDataStore.commitThenFailNext(self: FakeDataStore, n: number, message: string)
	self.commitFailures = n
	self.commitMessage = message
end

-- The next n calls run their transform twice: the first result is thrown away as if the write
-- had lost a race, and the second run gets a fresh copy of the record.
function FakeDataStore.rerunNext(self: FakeDataStore, n: number)
	self.reruns = n
end

-- Runs `hook` once, during the next call, after the transform has run and before the write.
function FakeDataStore.hookNext(self: FakeDataStore, hook: (key: string) -> ())
	table.insert(self.hooks, hook)
end

function FakeDataStore.UpdateAsync(self: FakeDataStore, key: string, transform: (any) -> any): any
	self.calls += 1
	if self.events then
		table.insert(self.events, "call " .. key)
	end
	if self.failures > 0 then
		self.failures -= 1
		error(self.failMessage)
	end
	local forcedReruns = 0
	if self.reruns > 0 then
		self.reruns -= 1
		forcedReruns = 1
	end
	local hook = table.remove(self.hooks, 1)
	while true do
		local before = self.records[key]
		local result = transform(Deep.copy(before))
		self.runs += 1
		if hook then
			local run = hook
			hook = nil
			run(key)
		end
		if forcedReruns > 0 then
			forcedReruns -= 1
		elseif result == nil then
			return Deep.copy(before) -- cancelled: nothing is written
		elseif self.records[key] == before then
			self.records[key] = Deep.copy(result)
			if self.commitFailures > 0 then
				self.commitFailures -= 1
				error(self.commitMessage)
			end
			return Deep.copy(result)
		end
		-- The record changed under us (or a re-run was forced): read it again and re-run.
	end
end

export type Handle = {
	UpdateAsync: (self: Handle, key: string, transform: (any) -> any) -> any,
	GetAsync: (self: Handle, key: string, options: any?) -> any,
}

export type HandleOptions = {
	-- Real GetAsync serves a key from a local cache for this many seconds after the first read.
	cacheSeconds: number?,
	-- The clock that cache runs on: the simulated server's own, so a skewed server caches by its time.
	clock: { now: (any) -> number }?,
}

-- One simulated server's view of this store. Every UpdateAsync counts as a write on `faults`
-- (a "stop" raises before the call reaches the store; a "lost" applies it and then raises) and
-- every call raises CRASH once the server is dead. Handles built on one store share its records.
-- With `options.cacheSeconds` the handle also keeps a read cache like Roblox's: a GetAsync within
-- that many seconds of the handle's read of a key returns the value it read then, and a write
-- through the same handle replaces the cached value with the one written, unless the response
-- was lost. Off by default.
function FakeDataStore.handle(self: FakeDataStore, faults: Faults.Faults, options: HandleOptions?): Handle
	local cacheSeconds = if options then options.cacheSeconds else nil
	local clock = if options then options.clock else nil
	local cache: { [string]: { value: any, at: number } } = {}
	local function cacheNow(): number
		assert(clock ~= nil, "a read cache needs a clock")
		return clock:now()
	end
	local handle = {}
	function handle.UpdateAsync(_: any, key: string, transform: (any) -> any): any
		local mode = faults:beforeWrite()
		local result = self:UpdateAsync(key, transform)
		-- A lost response never reached the client, so its cache cannot hold what the write wrote.
		if cacheSeconds ~= nil and result ~= nil and mode ~= "lost" then
			cache[key] = { value = Deep.copy(result), at = cacheNow() }
		end
		if mode == "lost" then
			Faults.lose()
		end
		return result
	end
	function handle.GetAsync(_: any, key: string, getOptions: any?): any
		faults:beforeRead()
		if cacheSeconds ~= nil and not (getOptions ~= nil and getOptions.UseCache == false) then
			local hit = cache[key]
			if hit ~= nil and cacheNow() - hit.at < cacheSeconds then
				return Deep.copy(hit.value)
			end
			local value = Deep.copy(self.records[key])
			cache[key] = { value = Deep.copy(value), at = cacheNow() }
			return value
		end
		return Deep.copy(self.records[key])
	end
	return handle :: Handle
end

return FakeDataStore
