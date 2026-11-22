--!strict
-- One simulated server's view of player profiles in the harness. There are no leases: every
-- server reads and writes `Player_<id>` records of the form { data, schema, savedAt }, last writer
-- wins, which is a harder case than the real lease. A new TestProfiles after a restart reads the
-- store again.
--
-- Two options exist for the specs, never for the kit:
-- - `gate(key)` runs before each UpdateAsync and may park the calling thread;
-- - `splitPayout` is a deliberately wrong layer. A save that carries a season entry which is
--   rewarded in memory but was not in the last stored copy first writes the profile with every such
--   entry's rewarded, tier and reward cleared (the Coins are in), and only then the full profile:
--   the paid flag in a second save.
local Config = require("../../src/shared/Config")
local Deep = require("./Deep")
local Faults = require("./Faults")
local Profile = require("../../src/server/Data/Profile")

local TestProfiles = {}
TestProfiles.__index = TestProfiles

type Handle = {
	UpdateAsync: (self: any, key: string, transform: (any) -> any) -> any,
	GetAsync: (self: any, key: string, options: any?) -> any,
}

export type Options = {
	gate: ((key: string) -> ())?,
	splitPayout: boolean?,
	startCoins: number?,
	now: (() -> number)?,
}

export type TestProfiles = typeof(setmetatable(
	{} :: {
		handle: Handle,
		faults: Faults.Faults,
		options: Options,
		profiles: { [number]: any },
		stored: { [number]: any }, -- the last copy this layer loaded or saved
	},
	TestProfiles
))

function TestProfiles.new(handle: Handle, faults: Faults.Faults, options: Options?): TestProfiles
	return setmetatable({
		handle = handle,
		faults = faults,
		options = options or {},
		profiles = {},
		stored = {},
	}, TestProfiles)
end

function TestProfiles.key(userId: number): string
	return "Player_" .. tostring(userId)
end

-- Loads the stored profile (or builds the default) and makes it the live one.
function TestProfiles.join(self: TestProfiles, userId: number): any
	local record = self.handle:GetAsync(TestProfiles.key(userId))
	local data: any
	if record ~= nil then
		data = Deep.copy(record.data)
	else
		data = Profile.new({ startingCoins = self.options.startCoins or Config.StartingCoins }).defaultData()
	end
	self.profiles[userId] = data
	self.stored[userId] = Deep.copy(data)
	return data
end

-- The live table, or nil when the player has not joined here.
function TestProfiles.get(self: TestProfiles, userId: number): any?
	return self.profiles[userId]
end

local function write(self: TestProfiles, userId: number, data: any)
	local key = TestProfiles.key(userId)
	local gate = self.options.gate
	if gate ~= nil and not self.faults.dead then
		gate(key)
	end
	local at = if self.options.now ~= nil then self.options.now() else 0
	self.handle:UpdateAsync(key, function(_: any): any
		return { data = Deep.copy(data), schema = 1, savedAt = at }
	end)
end

-- Entries rewarded in memory that the last stored copy does not hold as rewarded.
local function newlyPaid(self: TestProfiles, userId: number, data: any): boolean
	local before = self.stored[userId]
	for key, entry in data.seasons do
		local was = if before ~= nil then before.seasons[key] else nil
		if entry.rewarded and not (was ~= nil and was.rewarded) then
			return true
		end
	end
	return false
end

-- False when `staked` is not the live table; else one UpdateAsync writing a deep copy: true when
-- it landed, false on any raise (a crash included).
function TestProfiles.save(self: TestProfiles, userId: number, staked: any): boolean
	local live = self.profiles[userId]
	if live == nil or staked ~= live then
		return false
	end
	local data = Deep.copy(live)
	local ok = pcall(function()
		if self.options.splitPayout and newlyPaid(self, userId, data) then
			local early = Deep.copy(data)
			local before = self.stored[userId]
			for key, entry in early.seasons do
				local was = if before ~= nil then before.seasons[key] else nil
				if entry.rewarded and not (was ~= nil and was.rewarded) then
					entry.rewarded = false
					entry.tier = nil
					entry.reward = nil
				end
			end
			write(self, userId, early)
		end
		write(self, userId, data)
	end)
	if ok then
		self.stored[userId] = data
	end
	return ok
end

-- Saves and forgets.
function TestProfiles.leave(self: TestProfiles, userId: number): boolean
	local live = self.profiles[userId]
	local saved = false
	if live ~= nil then
		saved = self:save(userId, live)
	end
	self.profiles[userId] = nil
	self.stored[userId] = nil
	return saved
end

return TestProfiles
