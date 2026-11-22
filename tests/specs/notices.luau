--!strict
local Deep = require("../fakes/Deep")
local Notices = require("../../src/server/Notices")

local function profile(count: number): any
	local notices = {}
	for i = 1, count do
		table.insert(notices, { text = `n{i}`, at = i })
	end
	return { notices = notices }
end

return {
	{
		name = "add appends the notice and returns it",
		run = function()
			local p = profile(1)
			local added = Notices.add(p, "hello", 9, 5)
			assert(#p.notices == 2 and p.notices[2].text == "hello" and p.notices[2].at == 9)
			assert(added.notice == p.notices[2] and #added.dropped == 0)
		end,
	},
	{
		name = "add drops the oldest notices over the cap, and remove puts them back in order",
		run = function()
			local p = profile(3)
			local before = Deep.copy(p)
			local added = Notices.add(p, "new", 9, 3)
			assert(#p.notices == 3 and p.notices[1].text == "n2" and p.notices[3].text == "new")
			assert(#added.dropped == 1 and added.dropped[1].text == "n1")
			Notices.remove(p, added)
			assert(Deep.equal(p, before), "remove must restore the notices exactly")
		end,
	},
	{
		name = "remove takes only that notice out when others were added since",
		run = function()
			local p = profile(1)
			local first = Notices.add(p, "first", 5, 10)
			Notices.add(p, "second", 6, 10)
			Notices.remove(p, first)
			assert(#p.notices == 2 and p.notices[2].text == "second")
		end,
	},
}
