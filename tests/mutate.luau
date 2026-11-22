--!strict
-- Mutation runner. Each file in tests/mutants is a find-and-replace that breaks one behaviour in
-- src. The runner applies it to a throwaway copy of src and tests, runs the suite there and
-- requires a failure. The working tree is never touched; the copies live in the temp directory.
--
--   lune run tests/mutate                      every mutant, full suite (the gate)
--   lune run tests/mutate -- --self-check      prove the runner reports a stale, a harmless and a broken mutant
--   lune run tests/mutate -- name [name ...]   only the named mutants
local fs = require("@lune/fs")
local process = require("@lune/process")

type Mutant = { name: string, file: string, find: string, replace: string }
type Result = { name: string, status: "killed" | "survived" | "stale" | "broken", detail: string }

local function tempRoot(): string
	local base = process.env.TEMP or process.env.TMPDIR or "/tmp"
	return (string.gsub(base, "[/]+$", "")) .. "/tally-mutate"
end

local function countPlain(text: string, find: string): number
	local count, from = 0, 1
	while true do
		local at = string.find(text, find, from, true)
		if at == nil then
			return count
		end
		count += 1
		from = at + #find
	end
end

local function loadMutants(only: { string }): { Mutant }
	local names = fs.readDir("tests/mutants")
	table.sort(names)
	local out: { Mutant } = {}
	for _, file in names do
		local base = string.match(file, "^(.+)%.luau$")
		if base ~= nil and (#only == 0 or table.find(only, base) ~= nil) then
			table.insert(out, require("./mutants/" .. base) :: Mutant)
		end
	end
	return out
end

local function runOne(mutant: Mutant, dir: string): Result
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	fs.writeDir(dir)
	fs.copy("src", dir .. "/src")
	fs.copy("tests", dir .. "/tests")
	local path = dir .. "/" .. mutant.file
	if not fs.isFile(path) then
		return { name = mutant.name, status = "stale", detail = `{mutant.file} does not exist` }
	end
	local text = string.gsub(fs.readFile(path), "\r\n", "\n")
	local found = countPlain(text, mutant.find)
	if found ~= 1 then
		return {
			name = mutant.name,
			status = "stale",
			detail = `find matched {found} times in {mutant.file}, expected exactly 1`,
		}
	end
	local at = string.find(text, mutant.find, 1, true) :: number
	fs.writeFile(path, string.sub(text, 1, at - 1) .. mutant.replace .. string.sub(text, at + #mutant.find))

	local ran = process.spawn("lune", { "run", "tests/run" }, { cwd = dir })
	if ran.ok then
		return { name = mutant.name, status = "survived", detail = "every spec still passed" }
	end
	local failed: { string } = {}
	for line in string.gmatch(ran.stdout, "[^\r\n]+") do
		local spec = string.match(line, "^FAILED (%S+) ::")
		if spec ~= nil and table.find(failed, spec) == nil then
			table.insert(failed, spec)
		end
	end
	if #failed == 0 then
		-- Non-zero without a FAILED line: the mutant broke the build or the runner itself. That
		-- proves nothing about the specs, so it fails the run rather than counting as a kill.
		local first = string.match(ran.stderr .. ran.stdout, "[^\r\n]+") or "no output"
		return { name = mutant.name, status = "broken", detail = `did not run: {first}` }
	end
	return { name = mutant.name, status = "killed", detail = table.concat(failed, ", ") }
end

local function runAll(mutants: { Mutant }): { Result }
	local root = tempRoot()
	if fs.isDir(root) then
		fs.removeDir(root) -- left behind by an interrupted run
	end
	fs.writeDir(root)
	local results: { Result } = {}
	-- Clean up whatever happens inside the loop, then re-raise.
	local ok, err = pcall(function()
		for _, mutant in mutants do
			local result = runOne(mutant, root .. "/" .. mutant.name)
			table.insert(results, result)
			if result.status == "killed" then
				print(`KILLED {result.name} by {result.detail}`)
			elseif result.status == "survived" then
				print(`SURVIVED {result.name}`)
			elseif result.status == "broken" then
				print(`BROKEN {result.name}: {result.detail}`)
			else
				print(`STALE {result.name}: mutant {result.name} no longer applies ({result.detail})`)
			end
			fs.removeDir(root .. "/" .. mutant.name)
		end
	end)
	if fs.isDir(root) then
		fs.removeDir(root)
	end
	if not ok then
		error(err, 0)
	end
	return results
end

local function selfCheck(): boolean
	local harmless: Mutant = {
		name = "selfcheck_harmless",
		file = "src/shared/Config.luau",
		find = "return table.freeze({",
		replace = "-- harmless\nreturn table.freeze({",
	}
	local stale: Mutant = {
		name = "selfcheck_stale",
		file = "src/shared/Config.luau",
		find = "this text is not in Config.luau",
		replace = "x",
	}
	-- A mutant that stops src from loading must not count as a kill.
	local broken: Mutant = {
		name = "selfcheck_broken",
		file = "src/shared/Config.luau",
		find = "return table.freeze({",
		replace = "return table.freeze({{",
	}
	local results = runAll({ harmless, stale, broken })
	local good = results[1].status == "survived"
		and results[2].status == "stale"
		and results[3].status == "broken"
	print(
		if good then "self-check ok: harmless SURVIVED, stale STALE, broken BROKEN" else "self-check FAILED"
	)
	return good
end

local args = process.args
local check = false
local only: { string } = {}
for _, arg in args do
	if arg == "--self-check" then
		check = true
	else
		table.insert(only, arg)
	end
end

if check then
	process.exit(if selfCheck() then 0 else 1)
end

local mutants = loadMutants(only)
if #mutants == 0 then
	print("no mutants found")
	process.exit(1)
end
local results = runAll(mutants)
local killed, bad = 0, 0
for _, result in results do
	if result.status == "killed" then
		killed += 1
	else
		bad += 1
	end
end
print(`{killed} killed, {bad} survived, stale or broken, {#results} mutants`)
if bad > 0 then
	process.exit(1)
end
