--!strict
-- Demo game script: three prompts that score points through the server-only TallyRecord function.
-- Prompts are found by name anywhere under Workspace, so the scene layout is free.
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local record = ServerStorage:WaitForChild("TallyRecord") :: BindableFunction

local SOURCES = {
	BellPrompt = { points = 5, cooldown = 0 },
	RibbonPrompt = { points = 10, cooldown = 0 },
	JudgesPrompt = { points = 25, cooldown = 10 },
}

local lastUse: { [string]: number } = {}

local function wire(prompt: ProximityPrompt)
	local source = SOURCES[prompt.Name]
	if not source then
		return
	end
	prompt.Triggered:Connect(function(player: Player)
		local key = prompt.Name .. ":" .. player.UserId
		local now = os.clock()
		if source.cooldown > 0 and lastUse[key] and now - lastUse[key] < source.cooldown then
			return
		end
		lastUse[key] = now
		record:Invoke(player, source.points)
	end)
end

for _, inst in Workspace:GetDescendants() do
	if inst:IsA("ProximityPrompt") then
		wire(inst)
	end
end
Workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("ProximityPrompt") then
		wire(inst)
	end
end)

game:GetService("Players").PlayerRemoving:Connect(function(player)
	for key in lastUse do
		if string.sub(key, -#tostring(player.UserId) - 1) == ":" .. player.UserId then
			lastUse[key] = nil
		end
	end
end)
