--!strict
-- What a client can and can't make the server do, over a stub Tally.
local Config = require("../../src/shared/Config")
local FakeClock = require("../fakes/FakeClock")
local Handlers = require("../../src/server/Handlers")
local RateLimiter = require("../../src/shared/RateLimiter")
local Validate = require("../../src/shared/Validate")

type Rig = {
	handlers: any,
	calls: { string },
	syncs: { any },
	logs: { string },
	pages: { string },
	clock: any,
	state: { throws: boolean, busy: boolean, answer: any, park: boolean, tallyBusy: boolean },
	parked: any,
}

-- A tally that records what it was asked and answers from `state`. User 99 has no session.
local function rig(burst: number?): Rig
	local clock = FakeClock.new(0)
	local r: Rig = {
		handlers = nil,
		calls = {},
		syncs = {},
		logs = {},
		pages = {},
		clock = clock,
		state = { throws = false, busy = false, answer = true, park = false, tallyBusy = false },
		parked = nil,
	}
	local function now(): number
		return clock:now()
	end
	local tally = {
		claimStreak = function(_self: any, userId: number): (boolean, string?, number?)
			if r.state.throws then
				error("tally broke")
			end
			table.insert(r.calls, `claimStreak {userId}`)
			if r.state.park then
				r.state.park = false
				coroutine.yield()
			end
			if r.state.busy then
				return false, "busy", nil
			end
			if r.state.answer == true then
				return true, nil, 10
			end
			return false, r.state.answer, nil
		end,
		busy = function(): boolean
			return r.state.tallyBusy
		end,
	}
	r.handlers = Handlers.new({
		validate = Validate,
		limiter = RateLimiter.new(burst or 100, 1, now),
		storeLimiter = RateLimiter.new(
			Config.Limits.StoreBurstPerPlayer,
			Config.Limits.StoreOpsPerMinute / 60,
			now
		),
		storeCost = Config.Limits.StoreCost,
		config = Config,
		tally = tally,
		allowed = function(userId: number): boolean
			return userId ~= 99
		end,
		setPage = function(userId: number, page: number)
			table.insert(r.pages, `{userId} {page}`)
		end,
		sync = function(userId: number, result: any)
			table.insert(r.syncs, { userId = userId, result = result })
		end,
		log = function(message: string)
			table.insert(r.logs, message)
		end,
	})
	return r
end

local function dropped(r: Rig, ...: any)
	local before = r.handlers.dropped
	local calls, pages = #r.calls, #r.pages
	r.handlers:handle(1, ...)
	assert(#r.calls == calls and #r.pages == pages, "a dropped call did something")
	assert(#r.syncs == 0, "a dropped call is not synced")
	assert(r.handlers.dropped == before + 1, "and it is counted")
end

-- A small seeded generator, so the random cases are the same every run.
local function generator(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state
	end
end

return {
	{
		name = "every bad call is dropped and counted, with nothing synced",
		run = function()
			local nan = 0 / 0
			local r = rig()
			dropped(r)
			dropped(r, nil)
			dropped(r, 5)
			dropped(r, {})
			dropped(r, "")
			dropped(r, string.rep("a", 17))
			dropped(r, "settle")
			dropped(r, "claim_streak", 1)
			dropped(r, "claim_streak", {})
			dropped(r, "claim_streak", false)
			dropped(r, "board_page", 0)
			dropped(r, "board_page", 101)
			dropped(r, "board_page", 1.5)
			dropped(r, "board_page", "1")
			dropped(r, "board_page", nil)
			dropped(r, "board_page", nan)
			dropped(r, "board_page", math.huge)
			dropped(r, "board_page", {})
			dropped(r, "board_page", true)
			assert(r.handlers.dropped == 19, `{r.handlers.dropped} dropped`)
		end,
	},
	{
		name = "points cannot come from the client: record, score and every other action are dropped, and tally is never called",
		run = function()
			local r = rig()
			for _, name in { "record", "score", "add_points", "points", "setScore", "pay", "grant", "settle" } do
				dropped(r, name)
				dropped(r, name, 100)
				dropped(r, name, 1, 100)
			end
			dropped(r, "claim_streak", 100) -- a claim takes no argument, so it has no amount to carry
			assert(#r.calls == 0 and #r.pages == 0 and #r.syncs == 0)
			-- control: the two real actions still pass the same gate
			r.handlers:handle(1, "board_page", 2)
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == 1 and #r.pages == 1 and #r.syncs == 2)
		end,
	},
	{
		name = "a valid claim_streak calls tally once and syncs the reward, and a refusal syncs its reason, uncounted and unlogged",
		run = function()
			local r = rig()
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == 1 and r.calls[1] == "claimStreak 1", tostring(r.calls[1]))
			assert(#r.syncs == 1 and r.syncs[1].userId == 1)
			local res = r.syncs[1].result
			assert(res.action == "claim_streak" and res.ok == true and res.reward == 10 and res.reason == nil)
			r.state.answer = "already_claimed"
			r.handlers:handle(1, "claim_streak")
			res = r.syncs[2].result
			assert(res.action == "claim_streak" and res.ok == false and res.reason == "already_claimed")
			assert(res.reward == nil)
			assert(r.handlers.dropped == 0 and #r.logs == 0)
		end,
	},
	{
		name = "a valid board_page remembers the page and syncs ok, and never calls tally",
		run = function()
			local r = rig()
			r.handlers:handle(1, "board_page", 3)
			assert(#r.pages == 1 and r.pages[1] == "1 3")
			assert(#r.syncs == 1)
			local res = r.syncs[1].result
			assert(res.action == "board_page" and res.ok == true and res.reason == nil and res.reward == nil)
			assert(#r.calls == 0, "board_page never reaches tally")
			r.handlers:handle(1, "board_page", 1)
			r.handlers:handle(1, "board_page", 100)
			assert(r.pages[2] == "1 1" and r.pages[3] == "1 100" and r.handlers.dropped == 0)
		end,
	},
	{
		name = "the rate limiter: a burst of 3 and then dropped, one refill later one more, and limits are per player",
		run = function()
			local r = rig(3)
			for _ = 1, 3 do
				r.handlers:handle(1, "board_page", 2)
			end
			assert(#r.pages == 3 and r.handlers.dropped == 0)
			r.handlers:handle(1, "board_page", 2)
			assert(#r.pages == 3 and r.handlers.dropped == 1, "the fourth is dropped")
			r.clock:advance(1)
			r.handlers:handle(1, "board_page", 2)
			assert(#r.pages == 4, "one refill later one more passes")
			r.handlers:handle(1, "board_page", 2)
			assert(#r.pages == 4 and r.handlers.dropped == 2)
			r.handlers:handle(2, "board_page", 2)
			assert(#r.pages == 5 and r.pages[5] == "2 2", "another player has their own allowance")
		end,
	},
	{
		name = "a player with no saveable session is dropped, with nothing synced",
		run = function()
			local r = rig()
			r.handlers:handle(99, "claim_streak")
			r.handlers:handle(99, "board_page", 2)
			assert(#r.calls == 0 and #r.pages == 0 and #r.syncs == 0)
			assert(r.handlers.dropped == 2)
		end,
	},
	{
		name = "the busy guard: a second claim while one is parked is answered busy without calling tally again",
		run = function()
			local r = rig()
			r.state.park = true
			local co = coroutine.create(function()
				r.handlers:handle(1, "claim_streak")
			end)
			assert(coroutine.resume(co))
			assert(#r.calls == 1 and #r.syncs == 0, "the first is parked in tally")
			assert(r.handlers:busy(1) == true)
			assert(r.handlers:busy(2) == false)
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == 1, "tally was not called again")
			assert(#r.syncs == 1 and r.syncs[1].result.ok == false and r.syncs[1].result.reason == "busy")
			r.handlers:handle(1, "board_page", 2)
			assert(#r.pages == 0 and r.syncs[2].result.reason == "busy", "any call is busy meanwhile")
			assert(coroutine.resume(co))
			assert(r.handlers:busy(1) == false)
			assert(#r.syncs == 3 and r.syncs[3].result.reward == 10)
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == 2, "calls work again")
		end,
	},
	{
		name = "busy is true while tally says so, and a tally that answers busy is passed on as busy",
		run = function()
			local r = rig()
			r.state.tallyBusy = true
			assert(r.handlers:busy(1) == true)
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == 0 and r.syncs[1].result.reason == "busy", "a settle running here: busy")
			r.state.tallyBusy = false
			r.state.busy = true -- tally itself was busy when asked
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == 1 and r.syncs[2].result.ok == false and r.syncs[2].result.reason == "busy")
			assert(r.handlers.dropped == 2 and #r.logs == 0)
		end,
	},
	{
		name = "a tally that raises is counted, logged on one line and synced with nothing, and handle does not throw",
		run = function()
			local r = rig()
			r.state.throws = true
			r.handlers:handle(1, "claim_streak")
			assert(r.handlers.dropped == 1)
			assert(#r.logs == 1 and string.find(r.logs[1], "tally broke", 1, true), tostring(r.logs[1]))
			assert(not string.find(r.logs[1], "\n", 1, true))
			assert(#r.syncs == 1 and r.syncs[1].userId == 1 and r.syncs[1].result == nil)
			assert(r.handlers:busy(1) == false, "the guard is released")
			r.state.throws = false
			r.handlers:handle(1, "claim_streak")
			assert(r.syncs[2].result.ok == true)
		end,
	},
	{
		name = "a claim is charged to the store limiter by its cost, a board_page is not, and an over-budget claim is told to slow down",
		run = function()
			local r = rig()
			local cost = Config.Limits.StoreCost.claim_streak
			local allowed = Config.Limits.StoreBurstPerPlayer // cost
			for _ = 1, allowed do
				r.handlers:handle(1, "claim_streak")
			end
			assert(#r.calls == allowed, `{#r.calls} claims went through`)
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == allowed, "the next is held back")
			local last = r.syncs[#r.syncs].result
			assert(last.action == "claim_streak" and last.ok == false and last.reason == "slow_down")
			for _ = 1, 10 do
				r.handlers:handle(1, "board_page", 2)
			end
			assert(#r.pages == 10, "board_page is never charged")
			r.clock:advance(60 / Config.Limits.StoreOpsPerMinute * cost)
			r.handlers:handle(1, "claim_streak")
			assert(#r.calls == allowed + 1, "the allowance comes back")
			r.handlers:handle(2, "claim_streak")
			assert(#r.calls == allowed + 2, "another player has their own")
		end,
	},
	{
		name = "handle never throws, whatever it is given",
		run = function()
			local r = rig(1000)
			local next = generator(42)
			local pool: { any } = {
				nil,
				true,
				false,
				0,
				1,
				-1,
				3,
				100,
				101,
				1.5,
				0 / 0,
				math.huge,
				-math.huge,
				2 ^ 53,
				"",
				"claim_streak",
				"board_page",
				"record",
				"settle",
				string.rep("x", 300),
				{},
				{ "claim_streak" },
				function() end,
				coroutine.create(function() end),
			}
			local function pick(): any
				return pool[next() % (#pool + 1) + 1]
			end
			for _ = 1, 500 do
				local count = next() % 4
				local args: { any } = {}
				for i = 1, count do
					args[i] = pick()
				end
				local ok, err = pcall(function()
					r.handlers:handle(1 + next() % 3, table.unpack(args, 1, count))
				end)
				assert(ok, tostring(err))
			end
		end,
	},
}
