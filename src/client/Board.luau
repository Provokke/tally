--!strict
-- The Tally panel: season, time left, Coins, the top of the board, the player's rank and tier, the
-- streak button and the toasts. Thin by design: every number and sentence comes from BoardLogic and
-- the server's Sync. It sends intent only (a page number, or the streak claim) through `send`.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Tally")
local BoardLogic = require(Shared:WaitForChild("BoardLogic"))
local Config = require(Shared:WaitForChild("Config"))

local ROW_HEIGHT = 24
local WIDTH = 300
local TOAST_SECONDS = 6
local MAX_TOASTS_PER_SYNC = 5
local CLOSED_TEXT = "Season over. Rewards are paid when you next join."

local Board = {}
Board.__index = Board

export type Board = typeof(setmetatable(
	{} :: {
		theme: any,
		send: (action: string, arg: any?) -> (),
		userId: number,
		names: { [number]: string },
		asked: { [number]: boolean },
		sync: any?,
		syncedAt: number,
		lastLeft: string,
		toastCount: number,
		toasts: Frame,
		seasonLabel: TextLabel,
		timeLabel: TextLabel,
		coinLabel: TextLabel,
		emptyLabel: TextLabel,
		rows: { { frame: Frame, rank: TextLabel, name: TextLabel, score: TextLabel } },
		prev: TextButton,
		nextButton: TextButton,
		pageLabel: TextLabel,
		rankLabel: TextLabel,
		tierFill: Frame,
		tierLabel: TextLabel,
		streak: TextButton,
	},
	Board
))

local function place(item: GuiObject, x: number, y: number, w: number, h: number)
	item.Position = UDim2.fromOffset(x, y)
	item.Size = UDim2.fromOffset(w, h)
end

function Board.new(gui: ScreenGui, theme: any, send: (action: string, arg: any?) -> ()): Board
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -16, 0.5, 0)
	panel.Size = UDim2.fromOffset(WIDTH, 490)
	panel.Parent = gui
	theme.style(panel, theme.panel)

	local seasonLabel = theme.label(panel, "Season", 18)
	seasonLabel.FontFace = theme.fontBold
	place(seasonLabel, 14, 10, 150, 22)
	local coinLabel = theme.label(panel, "", 16, theme.coin)
	coinLabel.FontFace = theme.fontBold
	coinLabel.TextXAlignment = Enum.TextXAlignment.Right
	place(coinLabel, 150, 10, WIDTH - 164, 22)
	local timeLabel = theme.label(panel, "", 14, theme.muted)
	timeLabel.TextWrapped = true
	timeLabel.TextYAlignment = Enum.TextYAlignment.Top
	place(timeLabel, 14, 34, WIDTH - 28, 34)

	local rows = {}
	for i = 1, Config.BoardPageSize + 1 do
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Visible = false
		place(frame, 10, 72 + (i - 1) * ROW_HEIGHT, WIDTH - 20, ROW_HEIGHT - 2)
		frame.Parent = panel
		local rank = theme.label(frame, "", 14, theme.muted)
		place(rank, 6, 0, 38, ROW_HEIGHT - 2)
		local name = theme.label(frame, "", 14)
		name.TextWrapped = true
		name.TextYAlignment = Enum.TextYAlignment.Center
		place(name, 46, 0, 130, ROW_HEIGHT - 2)
		local score = theme.label(frame, "", 14, theme.muted)
		score.TextXAlignment = Enum.TextXAlignment.Right
		place(score, 176, 0, WIDTH - 20 - 176 - 6, ROW_HEIGHT - 2)
		rows[i] = { frame = frame, rank = rank, name = name, score = score }
	end
	local rowsBottom = 72 + (Config.BoardPageSize + 1) * ROW_HEIGHT

	local emptyLabel = theme.label(panel, "No scores yet.", 14, theme.muted)
	place(emptyLabel, 16, 76, WIDTH - 32, 22)
	emptyLabel.Visible = false

	local prev = theme.button(panel, "Previous")
	place(prev, 14, rowsBottom + 6, 90, 28)
	local nextButton = theme.button(panel, "Next")
	place(nextButton, WIDTH - 104, rowsBottom + 6, 90, 28)
	local pageLabel = theme.label(panel, "", 14, theme.muted)
	pageLabel.TextXAlignment = Enum.TextXAlignment.Center
	place(pageLabel, 104, rowsBottom + 6, WIDTH - 208, 28)

	local rankLabel = theme.label(panel, "", 15)
	place(rankLabel, 14, rowsBottom + 42, WIDTH - 28, 20)
	local tierBack = Instance.new("Frame")
	place(tierBack, 14, rowsBottom + 68, WIDTH - 28, 10)
	tierBack.Parent = panel
	theme.style(tierBack, theme.background)
	local tierFill = Instance.new("Frame")
	tierFill.Size = UDim2.fromScale(0, 1)
	tierFill.BackgroundColor3 = theme.accent
	tierFill.BorderSizePixel = 0
	tierFill.Parent = tierBack
	local tierLabel = theme.label(panel, "", 13, theme.muted)
	tierLabel.TextWrapped = true
	tierLabel.TextYAlignment = Enum.TextYAlignment.Top
	place(tierLabel, 14, rowsBottom + 84, WIDTH - 28, 34)

	local streak = theme.button(panel, "")
	streak.TextWrapped = true
	place(streak, 14, rowsBottom + 124, WIDTH - 28, 44)

	local toasts = Instance.new("Frame")
	toasts.Name = "Toasts"
	toasts.AnchorPoint = Vector2.new(1, 0)
	toasts.Position = UDim2.new(1, -16, 0, 16)
	toasts.Size = UDim2.fromOffset(WIDTH, 0)
	toasts.AutomaticSize = Enum.AutomaticSize.Y
	toasts.BackgroundTransparency = 1
	toasts.Parent = gui
	local toastLayout = Instance.new("UIListLayout")
	toastLayout.Padding = UDim.new(0, 8)
	toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	toastLayout.Parent = toasts

	local self: Board = setmetatable({
		theme = theme,
		send = send,
		userId = Players.LocalPlayer.UserId,
		names = {},
		asked = {},
		sync = nil,
		syncedAt = os.clock(),
		lastLeft = "",
		toastCount = 0,
		toasts = toasts,
		seasonLabel = seasonLabel,
		timeLabel = timeLabel,
		coinLabel = coinLabel,
		emptyLabel = emptyLabel,
		rows = rows,
		prev = prev,
		nextButton = nextButton,
		pageLabel = pageLabel,
		rankLabel = rankLabel,
		tierFill = tierFill,
		tierLabel = tierLabel,
		streak = streak,
	}, Board)

	prev.Activated:Connect(function()
		self:turn(-1)
	end)
	nextButton.Activated:Connect(function()
		self:turn(1)
	end)
	streak.Activated:Connect(function()
		local current = self.sync
		if current ~= nil and current.streak.canClaim then
			send("claim_streak")
		end
	end)
	return self
end

local function pageCount(entries: { any }): number
	return math.max(1, math.ceil(#entries / Config.BoardPageSize))
end

-- Asks for another page, clamped to the pages that exist. Sends the page number and nothing else.
function Board.turn(self: Board, step: number)
	local current = self.sync
	if current == nil then
		return
	end
	local page = math.clamp(current.board.page + step, 1, pageCount(current.board.entries))
	if page ~= current.board.page then
		self.send("board_page", page)
	end
end

-- A name for a userId: the cached one, or "Player <id>" while a lookup runs once in the background.
function Board.nameOf(self: Board, userId: number): string
	if userId == self.userId then
		return Players.LocalPlayer.DisplayName
	end
	local known = self.names[userId]
	if known ~= nil then
		return known
	end
	if not self.asked[userId] then
		self.asked[userId] = true
		task.spawn(function()
			local ok, name = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if ok and type(name) == "string" then
				self.names[userId] = name
				pcall(function()
					self:draw()
				end)
			end
		end)
	end
	return `Player {userId}`
end

-- Time left, from the last Sync and the time since it. Cheap: call it as often as you like.
function Board.tick(self: Board)
	local current = self.sync
	if current == nil then
		return
	end
	local text = CLOSED_TEXT
	if current.season.state ~= "closed" then
		local left = current.season.endsAt - current.serverNow - (os.clock() - self.syncedAt)
		text = `Time left: {BoardLogic.timeLeft(left)}`
	end
	if text ~= self.lastLeft then
		self.lastLeft = text
		self.timeLabel.Text = text
	end
end

-- Redraws everything except the toasts from the last good Sync.
function Board.draw(self: Board)
	local current = self.sync
	if current == nil then
		return
	end
	local theme = self.theme
	self.seasonLabel.Text = `Season {current.season.id}`
	self.coinLabel.Text = BoardLogic.coins(current.coins)
	self:tick()

	local entries = current.board.entries
	local pages = pageCount(entries)
	local page = math.clamp(current.board.page, 1, pages)
	local list =
		BoardLogic.pageRows(entries, page, Config.BoardPageSize, self.userId, current.score, current.rank)
	self.emptyLabel.Visible = #list == 0
	for i, row in self.rows do
		local data = list[i]
		row.frame.Visible = data ~= nil
		if data ~= nil then
			row.rank.Text = if data.rank ~= nil then `#{data.rank}` else "-"
			row.name.Text = self:nameOf(data.userId)
			row.score.Text = tostring(data.score)
			row.frame.BackgroundTransparency = if data.isMe then 0.7 else 1
			row.frame.BackgroundColor3 = theme.accent
			row.name.TextColor3 = if data.isMe then theme.text else theme.muted
		end
	end
	self.pageLabel.Text = `Page {page} of {pages}`
	theme.setEnabled(self.prev, page > 1)
	theme.setEnabled(self.nextButton, page < pages)

	self.rankLabel.Text = BoardLogic.rankText(current.rank, current.score, Config.BoardCacheSize)
	local progress = BoardLogic.tierProgress(current.score, Config.Tiers)
	self.tierFill.Size = UDim2.fromScale(progress.fraction, 1)
	self.tierLabel.Text = BoardLogic.tierText(progress)

	self.streak.Text = BoardLogic.streakText(current.streak)
	theme.setEnabled(self.streak, current.streak.canClaim == true, theme.accent)
end

local function isStreak(s: any): boolean
	return type(s) == "table"
		and type(s.count) == "number"
		and type(s.nextReward) == "number"
		and type(s.canClaim) == "boolean"
		and type(s.broken) == "boolean"
end

-- True when the payload has the shape the panel draws from.
local function good(s: any): boolean
	if type(s) ~= "table" or type(s.coins) ~= "number" or type(s.serverNow) ~= "number" then
		return false
	end
	local season, board = s.season, s.board
	if type(season) ~= "table" or type(board) ~= "table" or type(board.entries) ~= "table" then
		return false
	end
	for _, entry in board.entries do
		if type(entry) ~= "table" or type(entry.userId) ~= "number" or type(entry.score) ~= "number" then
			return false
		end
	end
	return type(season.id) == "number"
		and type(season.endsAt) == "number"
		and type(board.page) == "number"
		and type(s.score) == "number"
		and (s.rank == nil or type(s.rank) == "number")
		and isStreak(s.streak)
end

function Board.update(self: Board, sync: any)
	if type(sync) ~= "table" then
		return
	end
	if good(sync) then
		self.sync = sync
		self.syncedAt = os.clock()
		self:draw()
	end
	-- A result and notices are shown even when the rest of the payload could not be drawn.
	local result = sync.result
	if type(result) == "table" and type(result.action) == "string" and type(result.ok) == "boolean" then
		local reason = if type(result.reason) == "string" then result.reason else nil
		local reward = if type(result.reward) == "number" then result.reward else nil
		local text = BoardLogic.resultText(result.action, result.ok, reason, reward)
		if text ~= nil then
			self:toast(text, if result.ok then self.theme.good else self.theme.bad)
		end
	end
	if type(sync.notices) == "table" then
		local first = math.max(1, #sync.notices - MAX_TOASTS_PER_SYNC + 1)
		for i = first, #sync.notices do
			local notice = sync.notices[i]
			if type(notice) == "table" and type(notice.text) == "string" then
				self:toast(notice.text, self.theme.accent)
			end
		end
	end
end

-- A card that fades in, stays for six seconds in all, and fades out.
function Board.toast(self: Board, text: string, outline: Color3?)
	local theme = self.theme
	self.toastCount += 1
	local card = Instance.new("CanvasGroup")
	card.LayoutOrder = self.toastCount
	card.Size = UDim2.fromOffset(WIDTH, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.GroupTransparency = 1
	card.Parent = self.toasts
	theme.style(card, theme.panel, outline or theme.stroke)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = card
	local label = theme.label(card, text, 15)
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.TextWrapped = true
	task.spawn(function()
		local fadeIn = TweenService:Create(
			card,
			TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ GroupTransparency = 0 }
		)
		fadeIn:Play()
		task.wait(TOAST_SECONDS - 0.65)
		local fadeOut = TweenService:Create(
			card,
			TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ GroupTransparency = 1 }
		)
		fadeOut:Play()
		task.wait(0.4)
		card:Destroy()
	end)
end

return Board
