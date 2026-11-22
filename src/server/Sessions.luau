--!strict
-- The players on this server and their sessions: load on join, release on leave, autosave and
-- shutdown. Kept free of Roblox services so the lifecycle can be tested. The entry script passes
-- in the Players lookups, kicks, task.spawn and task.wait.
--
-- At most one load or release runs for a player at a time. A player who leaves and rejoins
-- quickly waits for the old release to land before the new load starts, so the new load reads
-- what the old session wrote instead of being locked out by it (or, worse, racing it).
--
-- A release on leave or shutdown first waits, for up to closeSeconds, until `inUse` says no score or
-- reward call for that player is still running (one can be waiting on a wallet that yields). The save
-- then holds the finished call, not half of it.
local Sessions = {}
Sessions.__index = Sessions

export type Deps = {
	store: any, -- a Store
	keyFor: (userId: number) -> string, -- the DataStore key for a player
	present: (player: any) -> boolean, -- the player is still in this server
	kick: (player: any, message: string) -> (),
	playerOf: (userId: number) -> any?, -- the player with this id, if they are here
	ready: (userId: number, session: any) -> (), -- a session went live: send the first Sync
	spawn: (fn: () -> ()) -> (),
	wait: (seconds: number) -> (),
	clock: () -> number,
	closeSeconds: number, -- how long close() waits, and how long a release may retry under it
	log: (message: string) -> (),
	inUse: ((userId: number) -> boolean)?, -- a score or reward call for this player is still running
}

export type Sessions = typeof(setmetatable(
	{} :: {
		deps: Deps,
		live: { [number]: any }, -- sessions in play, by UserId
		busy: { [number]: number }, -- loads and releases running for each player
		inFlight: number, -- loads and releases running for everyone, for close()
		closing: boolean,
	},
	Sessions
))

local POLL_SECONDS = 0.25
local RELEASE_RESERVE = 10 -- seconds of a shutdown limit kept for the release after the reward wait

local MESSAGES: { [string]: string } = {
	locked = "Your data is still open on another server. Rejoin in a minute.",
	error = "Couldn't load your data. Please rejoin.",
	lost = "Your data was opened on another server.",
}

function Sessions.new(deps: Deps): Sessions
	return setmetatable({ deps = deps, live = {}, busy = {}, inFlight = 0, closing = false }, Sessions)
end

local function begin(self: Sessions, userId: number)
	self.busy[userId] = (self.busy[userId] or 0) + 1
	self.inFlight += 1
end

local function finish(self: Sessions, userId: number)
	local left = (self.busy[userId] or 1) - 1
	self.busy[userId] = if left > 0 then left else nil
	self.inFlight -= 1
end

-- Waits, for up to `limit` seconds, for a score or reward call still running for this player to finish.
-- Returns how long it waited.
local function settle(self: Sessions, userId: number, limit: number): number
	local deps = self.deps
	local inUse = deps.inUse
	if inUse == nil or not inUse(userId) then
		return 0
	end
	local start = deps.clock()
	while inUse(userId) and deps.clock() < start + limit do
		deps.wait(0.1)
	end
	if inUse(userId) then
		deps.log(
			`a score or reward call for {userId} was still running after {limit} s, so it was released anyway`
		)
	end
	return deps.clock() - start
end

-- Releases in the background, once any score or reward call still running for the player has finished. The
-- player counts as busy until it is done.
local function releaseLater(self: Sessions, userId: number, session: any, waitLimit: number?)
	begin(self, userId)
	self.deps.spawn(function()
		local ok, err = pcall(function()
			-- Under a shutdown limit, keep part of it for the release itself, so a call that never
			-- finishes cannot leave the release one late try.
			local callWait = if waitLimit ~= nil
				then math.max(0, waitLimit - math.min(RELEASE_RESERVE, waitLimit / 2))
				else self.deps.closeSeconds
			local waited = settle(self, userId, callWait)
			session:release(if waitLimit ~= nil then math.max(0, waitLimit - waited) else nil)
		end)
		if not ok then
			self.deps.log(`release failed for {userId}: {tostring(err)}`)
		end
		finish(self, userId)
	end)
end

-- PlayerAdded. Yields until the session is live, the load fails (the player is kicked with the
-- reason), or the player leaves.
function Sessions.join(self: Sessions, userId: number, player: any)
	local deps = self.deps
	local function wanted(): boolean
		return not self.closing and deps.present(player)
	end
	-- Wait out anything still running for this player here: the release of a session they just
	-- left, or a load started by an earlier join.
	while self.busy[userId] ~= nil or self.live[userId] ~= nil do
		if not wanted() then
			return
		end
		deps.wait(POLL_SECONDS)
	end
	if not wanted() then
		return
	end
	begin(self, userId)
	local ok, err = pcall(function()
		local session, outcome = deps.store:load(deps.keyFor(userId), wanted)
		if session == nil then
			local message = MESSAGES[outcome]
			if message ~= nil and wanted() then
				deps.kick(player, message)
			end
			return
		end
		if not wanted() then
			-- They left, or the server started closing, while the load ran. Still inside the busy
			-- window, so a rejoin waits for this release too.
			session:release(if self.closing then deps.closeSeconds else nil)
			return
		end
		self.live[userId] = session
		deps.ready(userId, session)
	end)
	finish(self, userId)
	if not ok then
		deps.log(`join failed for {userId}: {tostring(err)}`)
	end
end

-- PlayerRemoving. The release carries on in the background, after any score or reward call still running.
function Sessions.leave(self: Sessions, userId: number)
	local session = self.live[userId]
	if session == nil then
		return
	end
	self.live[userId] = nil
	releaseLater(self, userId, session, nil)
end

-- The live session for a player, or nil when they have none or it has lost its lease. A
-- read-only session is returned so its data can still be shown.
function Sessions.get(self: Sessions, userId: number): any
	local session = self.live[userId]
	if session == nil or session.lost then
		return nil
	end
	return session
end

-- The live session only if anything it does would be saved, else nil. Placements, sales and
-- credits must all go through this and never through `get`.
function Sessions.writableSession(self: Sessions, userId: number): any
	if self:writable(userId) then
		return self.live[userId]
	end
	return nil
end

-- Whether anything this player's session does would be saved. False for a session that loaded
-- read-only (saved by a newer version of the game) or that has lost its lease. Such a session
-- must not spend or be credited.
function Sessions.writable(self: Sessions, userId: number): boolean
	local session = self.live[userId]
	return session ~= nil and not session.lost and not session.readOnly
end

-- Saves one player's session in the background. A session that finds its lease gone is kicked
-- rather than allowed to carry on unsaved.
function Sessions.save(self: Sessions, userId: number)
	local session = self.live[userId]
	if session == nil then
		return
	end
	local deps = self.deps
	deps.spawn(function()
		local ok, saved = pcall(function()
			return session:save()
		end)
		if not ok then
			deps.log(`save failed for {userId}: {tostring(saved)}`)
		elseif not saved and session.lost and self.live[userId] == session then
			local player = deps.playerOf(userId)
			if player ~= nil then
				deps.kick(player, MESSAGES.lost)
			end
		end
	end)
end

-- Saves one player's session now and waits for it. True only when the write landed. It goes
-- through the session's own save, which runs one at a time with the autosave and the release of
-- the same session, so the two never overlap and each writes the data as it is when it runs. A
-- read-only, lost or released session is never written, so it answers false. A session that finds
-- its lease gone is kicked, as with an autosave. `undo` is run inside the save's lock if the write
-- does not land, so the caller's rollback comes before any queued save or release.
function Sessions.saveNow(self: Sessions, userId: number, undo: (() -> ())?): boolean
	local session = self.live[userId]
	if session == nil or session.lost or session.readOnly or session.released then
		return false
	end
	local deps = self.deps
	local ok, saved = pcall(function()
		return session:save(undo)
	end)
	if not ok then
		deps.log(`save failed for {userId}: {tostring(saved)}`)
		return false
	end
	if saved == true then
		return true
	end
	if session.lost and self.live[userId] == session then
		local player = deps.playerOf(userId)
		if player ~= nil then
			deps.kick(player, MESSAGES.lost)
		end
	end
	return false
end

-- The autosave pass.
function Sessions.saveAll(self: Sessions)
	local ids = {}
	for userId in self.live do
		table.insert(ids, userId)
	end
	for _, userId in ids do
		self:save(userId)
	end
end

-- BindToClose. Releases every live session in parallel (each after any score or reward call still running),
-- then waits until every load and release still running (including loads for players who joined
-- just before) has finished, or until closeSeconds have passed. Loads still retrying stop at their
-- next attempt.
function Sessions.close(self: Sessions)
	local deps = self.deps
	self.closing = true
	local ids = {}
	for userId in self.live do
		table.insert(ids, userId)
	end
	for _, userId in ids do
		local session = self.live[userId]
		self.live[userId] = nil
		releaseLater(self, userId, session, deps.closeSeconds)
	end
	local deadline = deps.clock() + deps.closeSeconds
	while self.inFlight > 0 and deps.clock() < deadline do
		deps.wait(0.1)
	end
end

return Sessions
