--!strict
-- Tally client entry. Builds the panel and talks to the server. The client never changes a score or
-- a balance: it sends what the player tried to do (a page number, or the streak claim) and redraws
-- from the next Sync. It never sends a score, a season, a reward or a user id.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Tally")
local request = Shared:WaitForChild("Request") :: RemoteEvent
local sync = Shared:WaitForChild("Sync") :: RemoteEvent

local Theme = require(script.Theme)
local Board = require(script.Board)

local gui = Instance.new("ScreenGui")
gui.Name = "Tally"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local board = Board.new(gui, Theme, function(action: string, arg: any?)
	pcall(function()
		if arg == nil then
			request:FireServer(action)
		else
			request:FireServer(action, arg)
		end
	end)
end)

-- One bad payload must not stop the client: each Sync is handled inside a pcall.
sync.OnClientEvent:Connect(function(payload: any)
	pcall(function()
		board:update(payload)
	end)
end)

-- The time left is worked out from the last Sync, so it moves between Syncs. Redrawn once a second.
local elapsed = 0
RunService.Heartbeat:Connect(function(dt: number)
	elapsed += dt
	if elapsed >= 1 then
		elapsed = 0
		pcall(function()
			board:tick()
		end)
	end
end)
