--!strict
-- The harness's own checks, so a pass in the race and crash specs means something.
local Deep = require("../fakes/Deep")
local FakeScheduler = require("../fakes/FakeScheduler")
local TestProfiles = require("../fakes/TestProfiles")
local World = require("../harness/World")

local specs: { { name: string, run: () -> () } } = {}

local function add(name: string, run: () -> ())
	table.insert(specs, { name = name, run = run })
end

local function stored(w: World.World, userId: number): any
	local record = w.records["Player_" .. userId]
	return if record ~= nil then record.data else nil
end

add("world: two servers over one store read each other's writes", function()
	local w = World.new()
	local a, b = w:server("A"), w:server("B")
	w:seed(1, World.newProfile({}))
	a:join(1)
	assert(a:tick() == 1)
	assert(a:record(1, 7))
	assert(a:leave(1))
	local seen = b:join(1)
	assert(seen.seasons["1"].score == 7, "B must read what A saved")
	assert(b.tally:view(1).state == "open")
	assert(b:tick() == 1)
	assert(b.tally.known[1].state == "open", "B reads the season key A opened")
	assert(w.records["season/1"].state == "open")
end)

add(
	"world: a server killed by faults.dead can never write again, even when a parked thread resumes",
	function()
		local w = World.new()
		local a = w:server("A")
		w:seed(1, World.newProfile({}))
		local sched = FakeScheduler.new(w.clock)
		a.gate = function(_: string)
			sched:wait(5)
		end
		a:join(1)
		assert(a:record(1, 9))
		local saved: boolean? = nil
		sched:spawn(function()
			saved = a:leave(1)
		end)
		assert(saved == nil, "the save is parked on the gate")
		w:kill(a)
		local calls = w.store.calls
		sched:advance(10)
		assert(saved == false, "the parked save must fail on a dead server")
		assert(w.store.calls == calls, "a dead server's write reached the store")
		assert(stored(w, 1).seasons["1"] == nil, "the profile changed in the store")
		assert(a.faults.dead and #sched.sleeping == 0)
	end
)

add("world: restart is a new server that sees only the store", function()
	local w = World.new()
	local a = w:server("A")
	a:join(1)
	assert(a:record(1, 4))
	local b = w:restart(a, "B")
	assert(a.faults.dead and not b.faults.dead)
	assert(b:join(1).seasons["1"] == nil, "B must not see A's unsaved score")
	assert(a:leave(1) == false, "the old server can't save")
	assert(w.records["Player_1"] == nil)
end)

add("world: a server name used twice asserts", function()
	local w = World.new()
	w:server("A")
	local ok = pcall(function()
		w:server("A")
	end)
	assert(not ok, "a reused name would make closedBy ambiguous")
end)

add("world: skew shifts only that server's now", function()
	local w = World.new()
	local a, b = w:server("A"), w:server("B", { skew = -5 })
	assert(a:now() == 1000 and b:now() == 995)
	w.clock:advance(10)
	assert(a:now() == 1010 and b:now() == 1005 and w.clock:now() == 1010)
	assert(a.tally:currentId() == 1 and b.tally:currentId() == 1)
end)

add("world: quiesce on an already-settled world is quiet and pays nothing", function()
	local w = World.new()
	local paid = World.newProfile({ [1] = 60 }, 450)
	paid.seasons["1"].rewarded = true
	paid.seasons["1"].tier = "Silver"
	paid.seasons["1"].reward = 450
	w:seed(1, paid)
	w.records["season/1"] =
		{ id = 1, startsAt = 1000, endsAt = 1100, state = "closed", podium = {}, closedBy = "X" }
	w.clock:advance(200)
	local ok, why = w:quiesce()
	assert(ok, why)
	assert(stored(w, 1).coins == 450, "a settled profile is not paid again")
	assert(w:check(0))
	assert(w:quiesce(), "and again")
	assert(stored(w, 1).coins == 450)
end)

add("world: quiesce on a world with an unpaid season pays it", function()
	local w = World.new()
	w:seed(1, World.newProfile({ [1] = 60 }))
	w:seedBoard(1, { [1] = 60 })
	w.clock:advance(200)
	local ok, why = w:quiesce()
	assert(ok, why)
	local data = stored(w, 1)
	assert(data.seasons["1"].rewarded == true and data.coins == 450, tostring(data.coins))
	assert(w.records["season/1"].state == "closed")
	local conserved, reason = w:check(0)
	assert(conserved, reason)
end)

add("world: quiesce reports a profile layer that never lets a save land, naming the user", function()
	local w = World.new({
		quiesceOpts = {
			gate = function(_: string)
				error("no save lands")
			end,
		},
	})
	w:seed(2, World.newProfile({ [1] = 40 }))
	w:seedBoard(1, { [2] = 40 })
	w.clock:advance(200)
	local ok, why = w:quiesce()
	assert(not ok, "a world that can't be settled must not read as quiet")
	assert(string.find(why or "", "player 2", 1, true) ~= nil, tostring(why))
	assert(string.find(why or "", "unpaid", 1, true) ~= nil, tostring(why))
end)

add("world: quiesce stops at the round bound when payment never sticks", function()
	local w = World.new()
	w:seed(1, World.newProfile({ [1] = 60 }))
	w:seedBoard(1, { [1] = 60 })
	w.clock:advance(200)
	-- A payout that adds the Coins and never records the paid flag is paid again every round.
	local apply = require("../../src/server/Payout").apply
	w.opts.quiesceOpts = {
		deps = {
			Payout = setmetatable({
				apply = function(profile: any, key: string, decision: any): any
					local undo = apply(profile, key, decision)
					profile.seasons[key].rewarded = false
					return undo
				end,
			}, { __index = require("../../src/server/Payout") }),
		},
	}
	local ok, why = w:quiesce()
	assert(not ok, "an endless payer must hit the bound")
	assert(string.find(why or "", `not quiet after {World.MAX_ROUNDS} rounds`, 1, true) ~= nil, tostring(why))
	assert(string.find(why or "", "player 1", 1, true) ~= nil, tostring(why))
end)

add("world: seed and seedBoard write exactly what they say", function()
	local w = World.new({ rankLag = 5 })
	local data = World.newProfile({ [1] = 60, [2] = 5 }, 12)
	w:seed(3, data)
	assert(Deep.equal(stored(w, 3), data))
	assert(w.records["Player_3"].schema == 1)
	assert(stored(w, 3) ~= data, "seed must store a copy")
	assert(data.lifetime.points == 65 and data.coins == 12)
	w:seedBoard(1, { [1] = 60, [2] = 40 })
	local board = w:board(1)
	assert(board.current["1"] == 60 and board.current["2"] == 40)
	local count = 0
	for _ in board.current do
		count += 1
	end
	assert(count == 2)
	assert(#w:board(1):handle(w:server("A").faults):GetSortedAsync(false, 10):GetCurrentPage() == 0, "lagged")
	w.clock:advance(5)
	assert(#w:board(1):handle(w:server("B").faults):GetSortedAsync(false, 10):GetCurrentPage() == 2)
	assert(w:board(2) ~= w:board(1) and w:board(1) == w:board(1))
end)

add("world: TestProfiles.save refuses a table that is not the live one", function()
	local w = World.new()
	local a = w:server("A")
	a:join(1)
	local live = a.profiles:get(1)
	assert(live ~= nil)
	assert(a.profiles:save(1, Deep.copy(live)) == false, "a copy is not the live profile")
	assert(w.records["Player_1"] == nil)
	assert(a.profiles:save(2, live) == false, "a profile that never joined here")
	assert(a.profiles:save(1, live) == true)
	assert(w.records["Player_1"].data.coins == live.coins)
	assert(a.profiles:get(2) == nil)
	assert(TestProfiles.key(5) == "Player_5")
end)

add("world: a save that raises is false, and a leave forgets the profile", function()
	local w = World.new()
	local a = w:server("A")
	a:join(1)
	a.faults:arm(1, "lost")
	assert(a:autosave(1) == false, "a lost response is a failed save")
	assert(w.records["Player_1"] ~= nil, "a lost write still landed")
	assert(a:leave(1) == true)
	assert(a.profiles:get(1) == nil)
	assert(a:autosave(1) == false)
end)

add("world: splitPayout makes two writes for a paying save and one for any other", function()
	local w = World.new()
	w:seed(1, World.newProfile({ [1] = 60 }))
	local a = w:server("A", { splitPayout = true })
	local profile = a:join(1)
	local before = a.faults.writes
	assert(a:autosave(1))
	assert(a.faults.writes - before == 1, "nothing newly paid: one write")
	profile.seasons["1"].rewarded = true
	profile.seasons["1"].tier = "Silver"
	profile.seasons["1"].reward = 450
	profile.coins += 450
	before = a.faults.writes
	-- A stop between the two writes leaves the Coins with the flag clear.
	a.faults:arm(2, "stop")
	assert(a:autosave(1) == false)
	assert(a.faults.writes - before == 2)
	local half = stored(w, 1)
	assert(half.coins == 450 and half.seasons["1"].rewarded == false and half.seasons["1"].reward == nil)

	local w2 = World.new()
	w2:seed(1, World.newProfile({ [1] = 60 }))
	local c = w2:server("C", { splitPayout = true })
	local live = c:join(1)
	live.seasons["1"].rewarded = true
	live.seasons["1"].reward = 450
	live.coins += 450
	before = c.faults.writes
	assert(c:autosave(1))
	assert(c.faults.writes - before == 2, "a paying save is two writes")
	assert(stored(w2, 1).seasons["1"].rewarded == true)
	before = c.faults.writes
	assert(c:autosave(1))
	assert(c.faults.writes - before == 1, "the entry is stored paid now: one write")

	local w3 = World.new()
	w3:seed(1, World.newProfile({ [1] = 60 }))
	local plain = w3:server("P")
	local pp = plain:join(1)
	pp.seasons["1"].rewarded = true
	pp.seasons["1"].reward = 450
	pp.coins += 450
	assert(plain:autosave(1) and plain.faults.writes == 1, "an honest layer writes a paying save once")
end)

add("world: the trace numbers every write the server made and names its operation", function()
	local w = World.new()
	local a = w:server("A")
	a:join(1)
	a:tick()
	a:record(1, 5)
	a:push(1)
	a:autosave(1)
	a:leave(1)
	local kinds: { string } = {}
	for i, write in a.trace do
		assert(write.n == i, "the trace numbers match the Faults numbers")
		table.insert(kinds, write.kind)
	end
	assert(
		table.concat(kinds, ",") == "tick:season,push:board,autosave:profile,leave:profile",
		table.concat(kinds, ",")
	)
	assert(a.faults.writes == #a.trace)
end)

return specs
