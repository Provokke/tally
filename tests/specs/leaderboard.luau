--!strict
local FakeClock = require("../fakes/FakeClock")
local FakeOrderedDataStore = require("../fakes/FakeOrderedDataStore")
local FakeScheduler = require("../fakes/FakeScheduler")
local Faults = require("../fakes/Faults")
local Leaderboard = require("../../src/server/Leaderboard")

local REFRESH = 30

local function build(lag: number?, size: number?)
	local w: any = {}
	w.clock = FakeClock.new(1000)
	w.sched = FakeScheduler.new(w.clock)
	w.raw = FakeOrderedDataStore.new(w.clock, lag or 0)
	w.faults = Faults.new()
	w.handle = w.raw:handle(w.faults)
	w.logs = {}
	w.board = Leaderboard.new({
		store = function(_: number): any
			return w.handle
		end,
		now = function(): number
			return w.clock:now()
		end,
		size = size or 3,
		refreshSeconds = REFRESH,
		log = function(message: string)
			table.insert(w.logs, message)
		end,
	})
	return w
end

local function ids(entries: { Leaderboard.Entry }?): string
	assert(entries ~= nil, "expected entries")
	local out = {}
	for _, entry in entries do
		table.insert(out, `{entry.userId}:{entry.score}`)
	end
	return table.concat(out, ",")
end

return {
	{
		name = "read returns the top by score, ties by userId, and skips bad keys and zero values",
		run = function()
			local w = build()
			w.handle:SetAsync("103", 50)
			w.handle:SetAsync("101", 50)
			w.handle:SetAsync("102", 70)
			w.handle:SetAsync("104", 10)
			w.handle:SetAsync("abc", 99)
			w.handle:SetAsync("1.5", 98)
			w.handle:SetAsync("105", 0)
			local entries, why = w.board:read(1, 10)
			assert(why == nil)
			assert(ids(entries) == "102:70,101:50,103:50,104:10", ids(entries))
		end,
	},
	{
		name = "read with a count over 100 reads 100",
		run = function()
			local w = build()
			for i = 1, 120 do
				w.handle:SetAsync(tostring(1000 + i), i)
			end
			local entries = w.board:read(1, 150)
			assert(entries ~= nil and #entries == 100)
			assert(entries[1].score == 120)
		end,
	},
	{
		name = "read on a failing store returns nil and the reason, and does not throw",
		run = function()
			local w = build()
			w.handle = {
				GetSortedAsync = function()
					error("503 service down")
				end,
			}
			local entries, why = w.board:read(1, 3)
			assert(entries == nil)
			assert(why ~= nil and string.find(why, "503 service down", 1, true) ~= nil, tostring(why))
		end,
	},
	{
		name = "top called 100 times in one window makes one sorted read, and reads again after the window",
		run = function()
			local w = build()
			w.handle:SetAsync("101", 5)
			for _ = 1, 100 do
				w.board:top(1)
			end
			assert(w.raw.sortedReads == 1)
			w.clock:advance(REFRESH)
			w.board:top(1)
			assert(w.raw.sortedReads == 2)
		end,
	},
	{
		name = "top returns what read would, cut to size",
		run = function()
			local w = build(0, 3)
			for i = 1, 5 do
				w.handle:SetAsync(tostring(100 + i), i * 10)
			end
			local entries = w.board:top(1)
			assert(ids(entries) == ids(w.board:read(1, 3)))
			assert(#entries == 3 and ids(entries) == "105:50,104:40,103:30")
		end,
	},
	{
		name = "callers that arrive while a read is in flight get the previous entries",
		run = function()
			local w = build()
			w.handle:SetAsync("101", 5)
			assert(ids(w.board:top(1)) == "101:5")
			w.clock:advance(REFRESH)
			w.handle:SetAsync("102", 9)
			local parked = false
			w.faults.onRead = function()
				if not parked then
					parked = true
					w.sched:wait(5)
				end
			end
			local first: any = nil
			w.sched:spawn(function()
				first = w.board:top(1)
			end)
			assert(first == nil, "the first read is parked")
			for _ = 1, 5 do
				assert(ids(w.board:top(1)) == "101:5")
			end
			assert(w.raw.sortedReads == 1, "the parked read has not reached the store yet")
			w.sched:advance(5)
			assert(w.raw.sortedReads == 2)
			assert(ids(first) == "102:9,101:5")
			assert(ids(w.board:top(1)) == "102:9,101:5")
			assert(w.raw.sortedReads == 2)
		end,
	},
	{
		name = "a failed refresh keeps the previous entries, holds the window and logs once",
		run = function()
			local w = build()
			w.handle:SetAsync("101", 5)
			assert(ids(w.board:top(1)) == "101:5")
			w.clock:advance(REFRESH)
			w.faults.onRead = function()
				error("throttled")
			end
			for _ = 1, 4 do
				assert(ids(w.board:top(1)) == "101:5")
			end
			assert(w.raw.sortedReads == 1, "the failing read never reached the store")
			assert(#w.logs == 1, `logged {#w.logs} lines`)
		end,
	},
	{
		name = "push writes a new score once, a higher score again, never zero, and retries after a failure",
		run = function()
			local w = build()
			assert(w.board:push(1, 101, 5) == true)
			assert(w.faults.writes == 1 and w.handle:GetAsync("101") == 5)
			assert(w.board:push(1, 101, 5) == true)
			assert(w.faults.writes == 1, "the same score is not written twice")
			assert(w.board:push(1, 101, 8) == true)
			assert(w.faults.writes == 2 and w.handle:GetAsync("101") == 8)
			assert(w.board:push(1, 102, 0) == true)
			assert(w.faults.writes == 2, "zero is never written")
			w.faults:arm(1, "fail")
			assert(w.board:push(1, 103, 4) == false)
			assert(w.handle:GetAsync("103") == nil)
			assert(w.board:push(1, 103, 4) == true)
			assert(w.handle:GetAsync("103") == 4, "the failed score was not remembered")
		end,
	},
	{
		name = "with lag 60 a push is missing from top and from a read until it has aged",
		run = function()
			local w = build(60)
			w.board:push(1, 101, 5)
			w.clock:advance(60)
			assert(ids(w.board:top(1)) == "101:5")
			w.board:push(1, 102, 9)
			assert(w.handle:GetAsync("102") == 9, "a point read sees it at once")
			assert(ids(w.board:read(1, 3)) == "101:5", "a read at the close sees only what had aged")
			w.clock:advance(REFRESH)
			assert(ids(w.board:top(1)) == "101:5", "a window later it has aged 30 s of 60")
			w.clock:advance(REFRESH)
			assert(ids(w.board:top(1)) == "102:9,101:5", "after the lag and another window it shows")
		end,
	},
}
