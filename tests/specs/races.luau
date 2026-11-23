--!strict
-- Servers racing on one store. Each race is a function run(order, broken) that returns
-- { ok, why, world, log }: `ok` means every assertion of the race held, so the same function serves
-- the real run (assert(result.ok, result.why)) and its negative control (a `broken` world must give
-- not ok, with a `why` that says what went wrong).
--
-- Interleaving is saleyards' method: a server's gate parks its thread on a FakeScheduler for a
-- delay before each season write and each profile save, the order the writes were let through is
-- recorded in `log`, and the race asserts that the order it asked for really happened.
--
-- Setup in every race: season 1 is [1000, 1100), three players hold unpaid season 1 scores (1: 60,
-- 2: 40, 3: 5) written by world:seed, and the season key is opened by a tick at 1000. A close is
-- judged by a clock CloseGraceSeconds (60) behind the server's own.
local FakeScheduler = require("../fakes/FakeScheduler")
local Faults = require("../fakes/Faults")
local Leaderboard = require("../../src/server/Leaderboard")
local Payout = require("../../src/server/Payout")
local Season = require("../../src/server/Season")
local World = require("../harness/World")

type Order = "AB" | "BA"
type Broken = "live_podium" | "early_close" | "no_paid_flag"

type Result = { ok: boolean, why: string?, world: World.World, log: { string } }

local START_SCORES = { [1] = 60, [2] = 40, [3] = 5 }

local function seedPlayers(w: World.World, extra: { [number]: { [number]: number } }?)
	for userId, score in START_SCORES do
		local scores: { [number]: number } = { [1] = score }
		for id, more in (extra or {})[userId] or {} do
			scores[id] = more
		end
		w:seed(userId, World.newProfile(scores))
	end
end

local function stored(w: World.World, userId: number): any
	return w.records["Player_" .. userId].data
end

local function indexOf(log: { string }, line: string): number?
	return table.find(log, line)
end

-- A copy of a real module with some members replaced.
local function with(real: any, replaced: any): any
	local out: any = table.clone(real)
	for key, value in replaced do
		out[key] = value
	end
	return out
end

-- The deliberately broken modules, one per negative control.
local function brokenDeps(broken: Broken?, w: World.World): any?
	if broken == "live_podium" then
		-- Pays the podium bonus from the live board at the payout, not from the stored close.
		local board = Leaderboard.new({
			store = function(id: number): any
				return w:board(id):handle(Faults.new())
			end,
			now = function(): number
				return w.clock:now()
			end,
			size = 10,
			refreshSeconds = 15,
			log = function(_: string) end,
		})
		return {
			Payout = with(Payout, {
				decide = function(
					entry: any,
					season: any,
					id: number,
					currentId: number,
					userId: number,
					now: number,
					rules: any
				): any
					if season ~= nil and season.state == "closed" then
						local live = board:read(id, 3)
						season = {
							id = season.id,
							endsAt = season.endsAt,
							state = season.state,
							podium = live or {},
						}
					end
					return Payout.decide(entry, season, id, currentId, userId, now, rules)
				end,
			}),
		}
	elseif broken == "early_close" then
		-- A close with no not_ended check, and a decision that closes any open season.
		return {
			Season = with(Season, {
				close = function(current: any, now: number, podium: any, serverId: string): (any, string?)
					local at = if current ~= nil then math.max(now, current.endsAt) else now
					return Season.close(current, at, podium, serverId)
				end,
			}),
			Payout = with(Payout, {
				decide = function(
					entry: any,
					season: any,
					id: number,
					currentId: number,
					userId: number,
					now: number,
					rules: any
				): any
					local decision = Payout.decide(entry, season, id, currentId, userId, now, rules)
					if decision.action == "wait" and decision.reason == "not_ended" then
						return { action = "close" }
					end
					return decision
				end,
			}),
		}
	elseif broken == "no_paid_flag" then
		-- Adds the Coins and never records that the season was paid.
		return {
			Payout = with(Payout, {
				apply = function(profile: any, key: string, decision: any): any
					local undo = Payout.apply(profile, key, decision)
					profile.seasons[key].rewarded = false
					return undo
				end,
			}),
		}
	end
	return nil
end

-- Parks the server's thread before each gated write. `delay(key)` says for how long. The write is
-- logged as it is let through, so the log is the order the writes were allowed to land.
local function park(
	s: World.Server,
	sched: FakeScheduler.FakeScheduler,
	log: { string },
	delay: (string) -> number
)
	s.gate = function(key: string)
		sched:wait(delay(key))
		table.insert(log, `{s.name} {key}`)
	end
end

local function result(w: World.World, log: { string }, why: string?): Result
	return { ok = why == nil, why = why, world = w, log = log }
end

-- Quiet, and every Coin accounted for.
local function settledAndConserved(w: World.World): string?
	local quiet, why = w:quiesce()
	if not quiet then
		return `the world did not settle: {tostring(why)}`
	end
	local conserved, reason = w:check(w.config.StartingCoins)
	if not conserved then
		return `conservation: {tostring(reason)}`
	end
	return nil
end

-- The stored season key, and the user ids of its podium.
local function podiumOf(w: World.World, id: number): { number }
	local ids: { number } = {}
	for _, row in w.records["season/" .. id].podium do
		table.insert(ids, row.userId)
	end
	return ids
end

local function joined(ids: { number }): string
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, tostring(id))
	end
	return table.concat(parts, ",")
end

-- 1. Two servers close the same season with different podium views. Ranks lag by 10 s, so the board
-- read at 1200 shows the podium { 1, 2 } and a read after 1205 shows { 1, 2, 3 }. A reads at 1200
-- and parks at its close write, B reads at 1206 and closes, and A's close is then refused. In order
-- "BA" B starts and finishes first and A never writes a close at all. Both are paid from the stored
-- podium, which a late push to the board (player 4 at 1240) must not be able to change.
local function race1(order: Order, broken: Broken?): Result
	local w = World.new({ rankLag = 10 })
	local deps = brokenDeps(broken, w)
	local a, b = w:server("A", { deps = deps }), w:server("B", { deps = deps })
	seedPlayers(w)
	w:seedBoard(1, { [1] = 60, [2] = 40 }) -- at 1000: visible long before the close
	a:tick() -- opens season 1
	w.clock:advance(195)
	w:seedBoard(1, { [3] = 5 }) -- at 1195: visible from 1205
	w.clock:advance(5)
	local sched = FakeScheduler.new(w.clock)
	local log: { string } = {}
	local start = w.clock:now() -- 1200
	park(a, sched, log, function(key: string): number
		return if key == "season/1" and order == "AB" then 10 else 1
	end)
	park(b, sched, log, function(_: string): number
		return 1
	end)
	local function runA()
		sched:spawn(function()
			a:join(1)
			a:settle(1)
		end)
	end
	local function runB()
		sched:spawn(function()
			b:join(2)
			b:settle(2)
		end)
	end
	if order == "AB" then
		runA()
		sched:advance(6)
		runB()
		sched:advance(20)
	else
		sched:advance(6)
		runB()
		sched:advance(10)
		runA()
		sched:advance(20)
	end
	if #sched.sleeping ~= 0 then
		return result(w, log, "a thread is still parked after the race")
	end
	-- The order asked for really happened.
	local seasonWrites: { string } = {}
	for _, line in log do
		if string.find(line, "season/1", 1, true) ~= nil then
			table.insert(seasonWrites, line)
		end
	end
	if order == "AB" then
		if table.concat(seasonWrites, ";") ~= "B season/1;A season/1" then
			return result(w, log, `order AB: close writes were [{table.concat(seasonWrites, ";")}]`)
		end
	elseif table.concat(seasonWrites, ";") ~= "B season/1" then
		return result(
			w,
			log,
			`order BA: close writes were [{table.concat(seasonWrites, ";")}], A must write none`
		)
	end
	if w.clock:now() <= start + 6 then
		return result(w, log, "the clock did not move on")
	end
	-- The first write won, and A saw it refused.
	local season = w.records["season/1"]
	if season.state ~= "closed" or season.closedBy ~= "B" then
		return result(w, log, `season 1 was not closed by B: {season.state} by {tostring(season.closedBy)}`)
	end
	local known = a.tally.known[1]
	if known == nil or known.closedBy ~= "B" then
		return result(w, log, "A's close was not refused: A does not see B's close")
	end
	if joined(podiumOf(w, 1)) ~= "1,2,3" then
		return result(w, log, `the stored podium is not B's view: {joined(podiumOf(w, 1))}`)
	end
	-- A late push lands after the close; every payout must still come from the stored podium.
	sched:advance(1240 - w.clock:now())
	w:seedBoard(1, { [4] = 55 })
	sched:advance(11)
	sched:spawn(function()
		a:join(3)
		a:settle(3)
	end)
	sched:advance(10)
	local start0 = w.config.StartingCoins
	local owed: { [number]: number } = { [1] = 450, [2] = 250, [3] = 100 } -- tier + podium place
	for userId = 1, 3 do
		local data = stored(w, userId)
		if data.seasons["1"].rewarded ~= true or data.coins ~= start0 + owed[userId] then
			return result(
				w,
				log,
				`player {userId} was not paid from the stored podium: holds {data.coins} Coins, expected {start0 + owed[userId]}`
			)
		end
	end
	local why = settledAndConserved(w)
	return result(w, log, why)
end

-- 2. A server 5 s behind (B) and one 60 s ahead (A, the most the grace allows). At real 1101 A reads
-- 1161, closes season 1 (its close clock reads 1101) and pays player 1. At 1103 B reads 1098 and
-- still believes season 1 is current: it pays nothing and writes nothing, and its late record into
-- season 1 is refused once the profile has been paid. At 1106 B reads 1101 (season 2): it pays
-- player 2 from A's close. Player 2's season 2 score may not be closed by B until B's own close
-- clock has passed the end: at 1210 B reads 1205 (close clock 1145 of 1200) and must wait, at 1265
-- it reads 1260 and closes.
local function race2(_order: Order, broken: Broken?): Result
	local w = World.new()
	local deps = brokenDeps(broken, w)
	local a = w:server("A", { skew = 60, deps = deps })
	local b = w:server("B", { skew = -5, deps = deps })
	seedPlayers(w, { [2] = { [2] = 20 } })
	w:seedBoard(1, { [1] = 60, [2] = 40, [3] = 5 })
	local log: { string } = {}
	local start0 = w.config.StartingCoins
	-- A fast clock must wait out the grace: at real 1099 A reads 1159, past the end (1100), but its
	-- close clock reads 1099. A grace smaller than the skew would let it close and pay here.
	w.clock:advance(99)
	a:join(1)
	a:tick()
	-- A may look at season 1 (a no-op write to the season key), but must not close it or save a profile.
	local paid1 = a:settle(1)
	local season1 = w.records["season/1"]
	local profileWrites = 0
	for _, write in a.trace do
		if string.find(write.kind, ":profile", 1, true) ~= nil then
			profileWrites += 1
		end
	end
	if paid1 ~= 0 or season1.state ~= "open" or season1.closedBy ~= nil or profileWrites ~= 0 then
		return result(w, log, "season 1 closed early by A: its close clock was 1099 of 1100")
	end
	if stored(w, 1).coins ~= start0 then
		return result(w, log, "A paid player 1 before its close clock reached the end")
	end
	w.clock:advance(2) -- real 1101: A reads 1161
	if a:settle(1) ~= 1 then
		return result(w, log, "A did not pay player 1 at real 1101")
	end
	a:leave(1)
	if w.records["season/1"].closedBy ~= "A" or stored(w, 1).coins ~= start0 + 450 then
		return result(w, log, "A did not close season 1 and pay player 1 450")
	end
	w.clock:advance(2) -- real 1103: B reads 1098
	b:join(2)
	local before = b.faults.writes
	if b:settle(2) ~= 0 or b.faults.writes ~= before then
		return result(w, log, "B settled or wrote while it still believes season 1 is current")
	end
	if w.records["season/1"].closedBy == "B" then
		return result(w, log, "season 1 closed early by B")
	end
	b:join(1)
	local ok, why = b:record(1, 5)
	if ok or why ~= "already_rewarded" then
		return result(
			w,
			log,
			`B's late record answered {tostring(ok)}, {tostring(why)}, not already_rewarded`
		)
	end
	if stored(w, 1).seasons["1"].score ~= 60 or b.profiles:get(1).seasons["1"].score ~= 60 then
		return result(w, log, "B's refused record changed the score")
	end
	w.clock:advance(3) -- real 1106: B reads 1101, season 2
	if b:settle(2) ~= 1 or stored(w, 2).coins ~= start0 + 250 then
		return result(w, log, "B did not pay player 2 season 1 (50 + 200) from A's close")
	end
	w.clock:advance(104) -- real 1210: B reads 1205, close clock 1145
	before = b.faults.writes
	local early = b:settle(2)
	local season2 = w.records["season/2"]
	if early ~= 0 or b.faults.writes ~= before or season2.state ~= "open" or season2.closedBy ~= nil then
		return result(
			w,
			log,
			`season 2 closed early by B: B's close clock was 1145 of 1200 ({season2.state})`
		)
	end
	w.clock:advance(55) -- real 1265: B reads 1260, close clock 1200
	if b:settle(2) ~= 1 then
		return result(w, log, "B did not pay season 2 once its close clock passed the end")
	end
	season2 = w.records["season/2"]
	if season2.state ~= "closed" or season2.closedBy ~= "B" or stored(w, 2).coins ~= start0 + 300 then
		return result(w, log, "B did not close season 2 and pay 50 for it")
	end
	return result(w, log, settledAndConserved(w))
end

-- 3. A rejoin on another server mid-payout. There are no leases in the harness, so this is the hard
-- case. In order "AB" A's settle is parked at its payout save, the profile is loaded fresh on B (the
-- store still holds it unpaid), B pays and saves, and A's parked save lands after. In order "BA" A's
-- save lands before B loads.
local function race3(order: Order, broken: Broken?): Result
	local w = World.new()
	local deps = brokenDeps(broken, w)
	local a, b = w:server("A", { deps = deps }), w:server("B", { deps = deps })
	seedPlayers(w)
	w:seedBoard(1, { [1] = 60, [2] = 40, [3] = 5 })
	a:tick()
	w.clock:advance(200)
	local sched = FakeScheduler.new(w.clock)
	local log: { string } = {}
	park(a, sched, log, function(key: string): number
		return if key == "Player_1" and order == "AB" then 10 else 1
	end)
	park(b, sched, log, function(_: string): number
		return 1
	end)
	local loadedAfterA = false -- whether A's payout save had landed when B loaded the profile
	sched:spawn(function()
		a:join(1)
		a:settle(1)
	end)
	sched:advance(if order == "AB" then 3 else 5)
	if #sched.sleeping ~= (if order == "AB" then 1 else 0) then
		return result(w, log, `order {order}: A is not where the order says ({#sched.sleeping} parked)`)
	end
	sched:spawn(function()
		loadedAfterA = indexOf(log, "A Player_1") ~= nil
		b:join(1)
		b:settle(1)
	end)
	sched:advance(20)
	if #sched.sleeping ~= 0 then
		return result(w, log, "a thread is still parked after the race")
	end
	local first, second = indexOf(log, "B Player_1"), indexOf(log, "A Player_1")
	if order == "AB" then
		if loadedAfterA or first == nil or second == nil or first > second then
			return result(
				w,
				log,
				`order AB: B must load before A's save landed and save before A's parked save: [{table.concat(
					log,
					";"
				)}]`
			)
		end
	elseif not loadedAfterA or second == nil then
		return result(w, log, `order BA: B must load after A's save landed: [{table.concat(log, ";")}]`)
	end
	local data = stored(w, 1)
	local entry = data.seasons["1"]
	if entry.rewarded ~= true then
		return result(
			w,
			log,
			`player 1 season 1 is not marked rewarded after the race (rewarded={tostring(entry.rewarded)})`
		)
	end
	local paid = 0
	for _, season in data.seasons do
		if season.rewarded then
			paid += 1
		end
	end
	if data.coins ~= w.config.StartingCoins + 450 or entry.reward ~= 450 or paid ~= 1 then
		return result(
			w,
			log,
			`player 1 was not paid exactly once: {data.coins} Coins, reward {tostring(entry.reward)}`
		)
	end
	-- Exactly one payout in the whole store, not one per server.
	local total = 0
	for userId = 1, 3 do
		total += stored(w, userId).coins
	end
	if total ~= 3 * w.config.StartingCoins + 450 then
		return result(
			w,
			log,
			`the store holds {total} Coins, not three starts plus exactly one payout of 450`
		)
	end
	if order == "AB" and (indexOf(log, "A Player_1") == nil or indexOf(log, "B Player_1") == nil) then
		return result(w, log, "both servers must have saved player 1, or nothing raced")
	end
	return result(w, log, settledAndConserved(w))
end

type Race = (order: Order, broken: Broken?) -> Result

local specs: { { name: string, run: () -> () } } = {}

local function add(name: string, run: () -> ())
	table.insert(specs, { name = name, run = run })
end

local function control(label: string, race: Race, order: Order, broken: Broken, expected: string)
	add(`race control ({broken}, order {order}): {label}`, function()
		-- The real run of the same order passes, so a control that fails for any other reason is caught.
		local real = race(order, nil)
		assert(real.ok, `the unbroken run must pass: {tostring(real.why)}`)
		local outcome = race(order, broken)
		assert(not outcome.ok, "the broken world passed the race")
		assert(
			string.find(outcome.why or "", expected, 1, true) ~= nil,
			`why did not name {expected}: {tostring(outcome.why)}`
		)
	end)
end

for _, order in { "AB", "BA" :: Order } do
	local o: Order = order :: Order
	add(`race 1 ({o}): two servers close one season with different podium views`, function()
		local r = race1(o, nil)
		assert(r.ok, r.why)
	end)
	add(`race 3 ({o}): a rejoin on another server mid-payout pays once`, function()
		local r = race3(o, nil)
		assert(r.ok, r.why)
	end)
	control(
		"pays from the live board, not the stored podium",
		race1,
		o,
		"live_podium",
		"not paid from the stored podium"
	)
	control("never records the paid flag", race3, o, "no_paid_flag", "not marked rewarded after the race")
end

add("race 2: a server behind can't close early and its late record is refused once paid", function()
	local r = race2("AB", nil)
	assert(r.ok, r.why)
end)
control("closes a season before its close clock reaches the end", race2, "AB", "early_close", "closed early")

return specs
