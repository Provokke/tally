--!strict
-- Plain-words notices in a profile, oldest first, capped. add and remove are exact opposites, so
-- a payout or streak claim that has to be rolled back leaves the notices as they were.
local Notices = {}

export type Notice = { text: string, at: number }
export type Added = { notice: Notice, dropped: { Notice } }

function Notices.add(profile: any, text: string, now: number, cap: number): Added
	local notice: Notice = { text = text, at = now }
	table.insert(profile.notices, notice)
	local dropped: { Notice } = {}
	while #profile.notices > cap do
		table.insert(dropped, table.remove(profile.notices, 1))
	end
	return { notice = notice, dropped = dropped }
end

function Notices.remove(profile: any, added: Added)
	local at = table.find(profile.notices, added.notice)
	if at ~= nil then
		table.remove(profile.notices, at)
	end
	for i = #added.dropped, 1, -1 do
		table.insert(profile.notices, 1, added.dropped[i])
	end
end

return Notices
