--!strict
-- Crash injection for one simulated server. Every handle the server holds (DataStore or sorted
-- map) shares one Faults, so one counter numbers all of that server's writes in order.
--
-- `arm(k, "stop")` raises CRASH before write k is applied and kills the server: every later call
-- through any of its handles, reads included, raises CRASH too. `arm(k, "lost")` lets write k land
-- and then raises, as a call whose response never arrived does, and the server carries on.
-- `arm(k, "fail")` raises before write k is applied but leaves the server alive, as a request that
-- failed on our side and never reached the store does. `armPair(k1, k2)` loses two writes.
local Faults = {}
Faults.__index = Faults

export type Mode = "stop" | "lost" | "fail"

export type Faults = typeof(setmetatable(
	{} :: {
		writes: number,
		dead: boolean,
		target: number?, -- the write number that is armed
		mode: Mode,
		also: { [number]: boolean }, -- further write numbers that land and then raise
		onRead: (() -> ())?, -- runs at the start of every read, and may yield the calling thread
	},
	Faults
))

function Faults.new(): Faults
	return setmetatable(
		{ writes = 0, dead = false, target = nil, mode = "stop" :: Mode, also = {}, onRead = nil },
		Faults
	)
end

-- Arms write number k, counted from this call (the next write is 1).
function Faults.arm(self: Faults, k: number, mode: Mode)
	assert(k == math.floor(k) and k >= 1, "k must be a whole number from 1")
	assert(mode == "stop" or mode == "lost" or mode == "fail", "mode must be stop, lost or fail")
	self.target = self.writes + k
	self.mode = mode
end

-- Arms write numbers k1 and k2 (k1 < k2, both counted from this call), each landing and then
-- raising, so a spec can lose a write and the read-back that would have shown it.
function Faults.armPair(self: Faults, k1: number, k2: number)
	assert(k1 < k2, "k1 must come before k2")
	self:arm(k1, "lost")
	self.also[self.writes + k2] = true
end

-- Called at the start of every read. A dead server raises; a read is not a write.
function Faults.beforeRead(self: Faults)
	if self.onRead ~= nil then
		self.onRead()
	end
	if self.dead then
		error("CRASH")
	end
end

-- Called at the start of every write, before it is applied. Raises CRASH for a dead server or for
-- an armed "stop", and for an armed "fail" raises without killing. Returns "lost" when the write must be applied and then followed by
-- `Faults.lose`.
function Faults.beforeWrite(self: Faults): Mode?
	if self.dead then
		error("CRASH")
	end
	self.writes += 1
	if self.also[self.writes] then
		self.also[self.writes] = nil
		return "lost"
	end
	if self.target ~= nil and self.writes == self.target then
		self.target = nil
		if self.mode == "stop" then
			self.dead = true
			error("CRASH")
		end
		if self.mode == "fail" then
			error("request failed")
		end
		return "lost"
	end
	return nil
end

function Faults.lose()
	error("lost response")
end

return Faults
