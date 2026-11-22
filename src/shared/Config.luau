--!strict
return table.freeze({
	DataStoreName = "TallyPlayerData_v1", -- change it and every player starts fresh
	SeasonStoreName = "TallySeasons_v1", -- the DataStore holding one key per season, season/<id>, never deleted
	BoardStorePrefix = "tally-", -- the ordered store for season <id> is BoardStorePrefix .. id
	SchemaVersion = 1, -- bump when the saved data shape changes, and add a migration step
	AutosaveSeconds = 60, -- how often each session is written
	LeaseSeconds = 180, -- must be well over AutosaveSeconds, or a busy server loses its own lock
	LoadRetries = 5, -- attempts to load a profile before giving up
	RetryBaseSeconds = 1, -- doubles each retry: 1, 2, 4, 8 (five attempts, four waits)
	CloseTimeoutSeconds = 25, -- BindToClose gets about 30 s in total, leave headroom
	Epoch = 1767225600, -- 2026-01-01 00:00 UTC, season 1 starts here
	SeasonLengthSeconds = 1209600, -- 14 days
	DemoSeasonSeconds = 180, -- a Studio season when ServerStorage TallyDemoSeason is true
	StartingCoins = 0, -- what a new player's profile starts with
	ScoreMode = "sum", -- "sum" adds every submission, "best" keeps the highest single one
	ScoreStat = "points", -- the lifetime stat the kit raises
	MaxPointsPerCall = 1000, -- the most one record call may add
	PodiumSize = 3, -- how many top entries are frozen into the season key at the close
	PodiumBonus = table.freeze({ 300, 200, 100 }), -- Coins by podium place, one per PodiumSize
	-- Highest tier whose min the player's own score meets, in Coins. Ascending by min.
	Tiers = table.freeze({
		table.freeze({ name = "Bronze", min = 10, coins = 50 }),
		table.freeze({ name = "Silver", min = 50, coins = 150 }),
		table.freeze({ name = "Gold", min = 150, coins = 400 }),
	}),
	StreakRewards = table.freeze({ 10, 15, 20, 30, 40, 60, 100 }), -- Coins by streak count, capped at the last
	SettleSeconds = 60, -- how often players holding an unpaid old season are settled
	CloseGraceSeconds = 60, -- a season is closed only this long after its end by the closing server's clock
	PodiumWaitSeconds = 3600, -- how long past the end a close waits for a readable board before closing without a podium
	SeasonTickSeconds = 10, -- how often the server makes sure the current season key exists
	BoardPushSeconds = 30, -- how often each player's score is written to the ordered store
	BoardRefreshSeconds = 15, -- the most often one server reads the ordered store for Browse
	BoardCacheSize = 50, -- entries read per refresh, 1 to 100
	BoardPageSize = 10, -- entries per page the client shows
	NoticeCap = 20, -- how many notices a profile keeps, the oldest are dropped
	Limits = table.freeze({
		BurstPerPlayer = 6, -- remote calls a player can make in a burst
		RefillPerSecond = 2, -- calls handed back to each player per second
		-- A call that touches the DataStore (a streak claim saves the profile) draws from a second,
		-- slower allowance, so a loop of cheap-looking calls cannot use up the server's write budget.
		-- Roblox gives a server about 60 + 10 x players writes a minute, and autosaves use one per
		-- player, so six operations back a minute is two claim attempts sustained.
		StoreBurstPerPlayer = 6, -- store operations a player can spend in a burst
		StoreOpsPerMinute = 6, -- store operations handed back to each player per minute
		-- What each call spends. A claim is one save, costed at three to leave room for a retried write.
		StoreCost = table.freeze({ claim_streak = 3 }),
	}),
})
