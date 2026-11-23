--!strict
-- Crash at every write. Each scenario is a script of operations on server A. It is run clean to
-- count and name its writes (n), then once for every write k in 1..n in both modes: "stop" kills A
-- before write k lands, "lost" lets write k land and then raises. After each run every server is
-- dead, a fresh server settles until quiet, and the store's records must conserve Coins. A failure
-- names the scenario, k and the mode.
--
-- Only server A is crashed: a claim here covers one crashing server per scenario. In
-- restart_mid_settle B runs after the crash but its writes are not walked.
--
-- The walk is over the writes it observed, not a count it was given: the clean run records each
-- write A made (its number, its key and the operation that made it), every armed run must hit the
-- same write as the clean run did, and a scenario lists the kinds of write it has to cover, so a
-- write that is added later is walked and then named here rather than skipped.
local process = require("@lune/process")

local Payout = require("../../src/server/Payout")
local World = require("../harness/World")

local verbose = process.env.TALLY_VERBOSE ~= nil

type Step = (fn: () -> ()) -> ()

type Scenario = {
	name: string,
	-- The starting state: seeded records, the board and the clock (it is 1000 before this runs).
	setup: (w: World.World) -> (),
	-- Runs the operations. `step` runs one under pcall and skips the rest once A has crashed.
	run: (w: World.World, a: World.Server, step: Step) -> (),
	-- Checks the records of a clean run after quiesce (nil when it is fine).
	expect: ((records: { [string]: any }, w: World.World) -> string?)?,
	-- The fewest writes the clean run must make.
	minWrites: number,
	-- Every kind of write (`<operation>:<season|profile|board>`) the clean run makes.
	covers: { string },
}

local MODES: { "stop" | "lost" } = { "stop", "lost" }

local function data(records: { [string]: any }, userId: number): any
	return records["Player_" .. userId].data
end

local function first(...: string?): string?
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil then
			return v
		end
	end
	return nil
end

local function expectCoins(records: { [string]: any }, userId: number, coins: number): string?
	local held = data(records, userId).coins
	if held ~= coins then
		return `player {userId} holds {held} Coins, expected {coins}`
	end
	return nil
end

local function expectSeason(records: { [string]: any }, id: number, podium: { number }): string?
	local season = records["season/" .. id]
	if season == nil or season.state ~= "closed" then
		return `season {id} is not closed`
	end
	local ids: { string } = {}
	for _, row in season.podium do
		table.insert(ids, tostring(row.userId))
	end
	local want: { string } = {}
	for _, userId in podium do
		table.insert(want, tostring(userId))
	end
	if table.concat(ids, ",") ~= table.concat(want, ",") then
		return `season {id} podium is {table.concat(ids, ",")}, expected {table.concat(want, ",")}`
	end
	return nil
end

-- Server options for the world being played (a deliberately wrong layer, for a negative control),
-- so a scenario that builds a second server gives it the same ones.
local active: World.ServerOpts? = nil

-- Season 1 is [1000, 1100); a season is closed only once the server's clock is 60 s past its end.
local function closeAndPay(w: World.World, a: World.Server, step: Step)
	step(function()
		w.clock:advance(200)
	end)
	step(function()
		a:tick()
	end)
	for _, userId in { 1, 2 } do
		step(function()
			a:join(userId)
		end)
		step(function()
			a:settle(userId)
		end)
	end
	for _, userId in { 1, 2 } do
		step(function()
			a:leave(userId)
		end)
	end
end

local function seedClosePlayers(w: World.World)
	w:seed(1, World.newProfile({ [1] = 60 }))
	w:seed(2, World.newProfile({ [1] = 40 }))
	w:seedBoard(1, { [1] = 60, [2] = 40 })
end

local function closeAndPayEnd(records: { [string]: any }): string?
	return first(
		expectCoins(records, 1, 450), -- Silver 150, first on the podium 300
		expectCoins(records, 2, 250), -- Bronze 50, second on the podium 200
		expectSeason(records, 1, { 1, 2 })
	)
end

local DAY = 86400

local scenarios: { Scenario } = {
	{
		name = "close_and_pay",
		setup = seedClosePlayers,
		run = closeAndPay,
		expect = closeAndPayEnd,
		minWrites = 6,
		covers = { "tick:season", "settle:season", "settle:profile", "leave:profile" },
	},
	{
		-- Two closes and two payout saves in one settle.
		name = "two_seasons",
		setup = function(w)
			w:seed(1, World.newProfile({ [1] = 60, [2] = 25 }))
			w:seedBoard(1, { [1] = 60 })
			w:seedBoard(2, { [1] = 25 })
		end,
		run = function(w, a, step)
			step(function()
				w.clock:advance(300)
			end)
			step(function()
				a:join(1)
			end)
			step(function()
				a:settle(1)
			end)
			step(function()
				a:leave(1)
			end)
		end,
		expect = function(records)
			return first(
				expectCoins(records, 1, 450 + 350), -- season 1: Silver and first; season 2: Bronze and first
				expectSeason(records, 1, { 1 }),
				expectSeason(records, 2, { 1 })
			)
		end,
		minWrites = 5,
		covers = { "settle:season", "settle:profile", "leave:profile" },
	},
	{
		name = "streak",
		setup = function(w)
			w.clock:advance(100000 - 1000) -- UTC day 1: a claim is refused on day 0
		end,
		run = function(w, a, step)
			step(function()
				a:join(1)
			end)
			step(function()
				a:claim(1)
			end)
			step(function()
				w.clock:advance(DAY)
			end)
			step(function()
				a:claim(1)
			end)
			step(function()
				a:leave(1)
			end)
		end,
		expect = function(records)
			local streak = data(records, 1).streak
			if streak.count ~= 2 or streak.earned ~= 25 then
				return `streak is {streak.count} days and {streak.earned} earned, expected 2 and 25`
			end
			return expectCoins(records, 1, 25)
		end,
		minWrites = 3,
		covers = { "claim:profile", "leave:profile" },
	},
	{
		name = "score_push_autosave_release",
		setup = function(_) end,
		run = function(_, a, step)
			step(function()
				a:tick()
			end)
			step(function()
				a:join(1)
			end)
			step(function()
				a:record(1, 30)
			end)
			step(function()
				a:push(1)
			end)
			step(function()
				a:autosave(1)
			end)
			step(function()
				a:record(1, 20)
			end)
			step(function()
				a:push(1)
			end)
			step(function()
				a:leave(1)
			end)
		end,
		expect = function(records, w)
			local score = data(records, 1).seasons["1"].score
			if score ~= 50 then
				return `the stored score is {score}, expected 50`
			end
			local board = w:board(1).current["1"]
			if board ~= 50 then
				return `the board shows {tostring(board)}, expected 50`
			end
			return nil
		end,
		minWrites = 5,
		covers = { "tick:season", "push:board", "autosave:profile", "leave:profile" },
	},
	{
		-- A record after the season has ended belongs to the next season, so the season 1 payout is for
		-- the score of 10 and the late points are paid with season 2.
		name = "record_across_season_end",
		setup = function(_) end,
		run = function(w, a, step)
			step(function()
				w.clock:advance(99) -- 1099
			end)
			step(function()
				a:join(1)
			end)
			step(function()
				a:record(1, 10)
			end)
			step(function()
				a:push(1)
			end)
			step(function()
				w.clock:advance(2) -- 1101
			end)
			step(function()
				a:tick()
			end)
			local ok, why = nil, nil
			step(function()
				ok, why = a:record(1, 10)
			end)
			if not a.faults.dead then
				assert(ok == true, `the late record answered {tostring(ok)}, {tostring(why)}`)
			end
			step(function()
				w.clock:advance(60) -- 1161: the close clock is 1101
			end)
			step(function()
				a:settle(1)
			end)
			step(function()
				a:leave(1)
			end)
		end,
		expect = function(records)
			local seasons = data(records, 1).seasons
			if seasons["1"].score ~= 10 then
				return `season 1 score is {seasons["1"].score}: the late record reached it`
			end
			if seasons["2"] == nil or seasons["2"].score ~= 10 then
				return "the late record is not in season 2"
			end
			-- Season 1: Bronze 50 and first on the podium 300; season 2: Bronze 50.
			return first(expectCoins(records, 1, 400), expectSeason(records, 1, { 1 }))
		end,
		minWrites = 5,
		covers = { "push:board", "tick:season", "settle:season", "settle:profile", "leave:profile" },
	},
	{
		-- A is killed after its script and a second server continues, so a half-written state is read
		-- by a live server and not only by the quiesce.
		name = "restart_mid_settle",
		setup = seedClosePlayers,
		run = function(w, a, step)
			closeAndPay(w, a, step)
			w:kill(a)
			local b = w:server("B", active)
			b:tick()
			for _, userId in { 1, 2 } do
				b:join(userId)
				b:settle(userId)
				local entry = b.profiles:get(userId).seasons["1"]
				assert(entry.rewarded == true, `B left player {userId} unpaid after settling`)
			end
			for _, userId in { 1, 2 } do
				b:leave(userId)
			end
		end,
		expect = closeAndPayEnd,
		minWrites = 6,
		covers = { "tick:season", "settle:season", "settle:profile", "leave:profile" },
	},
}

type Failure = { k: number, mode: string, why: string }
type Walk = {
	name: string,
	n: number, -- the writes A made in the clean run
	trace: { World.Write }, -- the clean run's writes
	runs: number,
	failures: { Failure },
	hits: { [string]: { stop: number, lost: number } }, -- armed runs by kind of write and mode
}
type Run = {
	trace: { World.Write }, -- the writes A made
	world: World.World,
	why: string?, -- the reason when it is not quiet or does not conserve
}

-- Runs one scenario on a fresh world. `k` arms server A at its k-th write in `mode`; the armed
-- write must really fire, or the run would be a clean one in disguise. Then every server is dead and
-- a fresh server settles until quiet, and the store's records are checked.
local function play(sc: Scenario, sopts: World.ServerOpts?, k: number?, mode: string?): Run
	local w = World.new()
	sc.setup(w)
	active = sopts
	local a = w:server("A", sopts)
	if k ~= nil and mode ~= nil then
		a.faults:arm(k, mode :: any)
	end
	local crashed = false
	local function step(fn: () -> ())
		if crashed or a.faults.dead then
			crashed = true
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			if a.faults.dead then
				crashed = true
			else
				error("an operation raised while A was alive: " .. tostring(err), 0)
			end
		end
	end
	sc.run(w, a, step)
	if k ~= nil then
		assert(
			a.faults.target == nil,
			`armed write {k} ({mode}) never fired, A made {a.faults.writes} writes`
		)
		if mode == "stop" then
			assert(a.faults.dead, "a stop did not kill A")
		end
	end
	local trace = table.clone(a.trace)
	local quiet, why = w:quiesce()
	if not quiet then
		return { trace = trace, world = w, why = why }
	end
	local conserved, reason = w:check(w.config.StartingCoins)
	return { trace = trace, world = w, why = if conserved then nil else reason }
end

local function kindsOf(trace: { World.Write }): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, write in trace do
		if not seen[write.kind] then
			seen[write.kind] = true
			table.insert(out, write.kind)
		end
	end
	table.sort(out)
	return out
end

-- The clean run first (k = 0), then every write k in 1..n in both modes. Every armed run must hit
-- the write the clean run made at k.
local function walk(sc: Scenario, sopts: World.ServerOpts?): Walk
	local clean = play(sc, sopts, nil, nil)
	local out: Walk = {
		name = sc.name,
		n = #clean.trace,
		trace = clean.trace,
		runs = 0,
		failures = {},
		hits = {},
	}
	if clean.why ~= nil then
		table.insert(out.failures, { k = 0, mode = "clean", why = clean.why })
	elseif sc.expect ~= nil then
		local bad = sc.expect(clean.world.records, clean.world)
		if bad ~= nil then
			table.insert(out.failures, { k = 0, mode = "clean", why = "unexpected end state: " .. bad })
		end
	end
	for k = 1, out.n do
		local write = clean.trace[k]
		if write.n ~= k then
			table.insert(
				out.failures,
				{ k = 0, mode = "clean", why = `write {k} is numbered {write.n} in the trace` }
			)
		end
		for _, mode in MODES do
			out.runs += 1
			local ran, result = pcall(play, sc, sopts, k, mode)
			if not ran then
				table.insert(out.failures, { k = k, mode = mode, why = tostring(result) })
				continue
			end
			local finished = result :: Run
			local hit = finished.trace[k]
			if hit == nil or hit.key ~= write.key or hit.kind ~= write.kind then
				table.insert(out.failures, {
					k = k,
					mode = mode,
					why = `the armed run did not hit the clean run's write {k} ({write.kind} {write.key})`,
				})
			else
				local counts = out.hits[write.kind] or { stop = 0, lost = 0 }
				out.hits[write.kind] = counts
				counts[mode] += 1
			end
			if finished.why ~= nil then
				table.insert(out.failures, { k = k, mode = mode, why = finished.why })
			end
		end
	end
	if verbose then
		local lines: { string } = {}
		for _, write in clean.trace do
			table.insert(lines, `{write.n}={write.kind} {write.key}`)
		end
		print(
			`crash walk: {sc.name}: n={out.n}, runs={out.runs}, failures={#out.failures}: {table.concat(
				lines,
				", "
			)}`
		)
	end
	return out
end

local function describe(result: Walk): string
	local lines: { string } = {}
	for _, f in result.failures do
		table.insert(lines, `{result.name} k={f.k} mode={f.mode}: {f.why}`)
	end
	return table.concat(lines, "\n")
end

local function cleanRunPassed(result: Walk): boolean
	for _, f in result.failures do
		if f.k == 0 then
			return false
		end
	end
	return true
end

-- True when the walk failed at write k in `mode` with a reason that contains `text`.
local function failedAt(result: Walk, k: number, mode: string, text: string): boolean
	for _, f in result.failures do
		if f.k == k and f.mode == mode and string.find(string.lower(f.why), text, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function byName(name: string): Scenario
	for _, sc in scenarios do
		if sc.name == name then
			return sc
		end
	end
	error("no scenario named " .. name)
end

local function assertWalk(sc: Scenario, result: Walk)
	assert(
		result.n >= sc.minWrites,
		`{sc.name}: the clean run made {result.n} writes, expected at least {sc.minWrites}`
	)
	assert(
		result.runs == #MODES * result.n,
		`{sc.name}: walk ran {result.runs} times, expected {#MODES * result.n}`
	)
	local kinds = kindsOf(result.trace)
	local want = table.clone(sc.covers)
	table.sort(want)
	assert(
		table.concat(kinds, ",") == table.concat(want, ","),
		`{sc.name}: the writes made are [{table.concat(kinds, ",")}], the scenario lists [{table.concat(
			want,
			","
		)}]`
	)
	for _, kind in sc.covers do
		local counts = result.hits[kind]
		assert(
			counts ~= nil and counts.stop >= 1 and counts.lost >= 1,
			`{sc.name}: no stop and lost run hit a {kind} write`
		)
	end
	assert(#result.failures == 0, describe(result))
end

local specs: { { name: string, run: () -> () } } = {}

for _, sc in scenarios do
	table.insert(specs, {
		name = "crash every write: " .. sc.name,
		run = function()
			assertWalk(sc, walk(sc, nil))
		end,
	})
end

-- Negative controls: the same walk of a broken world must fail.

-- The paid flag in a second save: a stop between the two saves leaves the Coins in with the flag
-- clear, and the quiesce pays again.
table.insert(specs, {
	name = "crash control: the paid flag in a separate save fails the walk",
	run = function()
		local sc = byName("close_and_pay")
		local result = walk(sc, { splitPayout = true })
		assert(cleanRunPassed(result), `the control must be right on a clean run:\n{describe(result)}`)
		assert(result.n > #walk(sc, nil).trace, "the split layer must make more writes than the real one")
		assert(#result.failures >= 1, "the split payout passed the walk")
		local named = false
		for _, f in result.failures do
			if
				f.k >= 1
				and (
					string.find(f.why, "Coins", 1, true) ~= nil
					or string.find(f.why, "rewarded", 1, true) ~= nil
				)
			then
				named = true
			end
		end
		assert(named, `no failure at a crash point names Coins or rewarded:\n{describe(result)}`)
		assert(string.find(describe(result), "close_and_pay", 1, true) ~= nil)
		-- The stop between the two saves is the one that doubles the payout.
		assert(failedAt(result, 5, "stop", "coins"), describe(result))
	end,
})

-- A payout that never records the paid flag: the clean run itself is paid again every round.
table.insert(specs, {
	name = "crash control: a payout with no paid flag fails the clean run",
	run = function()
		local noFlag: any = table.clone(Payout)
		noFlag.apply = function(profile: any, key: string, decision: any): any
			local undo = Payout.apply(profile, key, decision)
			profile.seasons[key].rewarded = false
			return undo
		end
		local result = walk(byName("close_and_pay"), { deps = { Payout = noFlag } })
		assert(not cleanRunPassed(result), "the clean run of a payout with no paid flag passed")
		assert(failedAt(result, 0, "clean", "coins"), describe(result))
	end,
})

return specs
