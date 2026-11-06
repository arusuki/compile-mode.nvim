-- Compare only capture extraction, holding every other runtime module fixed.
-- Export baseline with git show REV:lua/compile-mode/errors/fast.lua, then set
-- CAPTURES_BASELINE to that file and run with scripts/minimal_init.lua.
local s = require("scripts.support")
s.setup()
local fast = require("compile-mode.errors.fast")
local before = dofile(assert(vim.env.CAPTURES_BASELINE, "CAPTURES_BASELINE must name the baseline fast.lua")).captures
local after = fast.captures
local regex = require("compile-mode.errors.matchers").gnu.regex
local rx = vim.regex(regex)
local data = {}
for i = 1, 10000 do
	data[i] = ("file.c:%d:1: error: failure"):format(i)
end
local results = {}
for _, mode in ipairs({ "captures", "parse" }) do
	local rows = { before = {}, after = {} }
	for iteration = 0, 7 do
		for _, name in ipairs(iteration % 2 == 0 and { "before", "after" } or { "after", "before" }) do
			fast.captures = name == "before" and before or after
			require("compile-mode.state").reset()
			local buf = mode == "parse" and s.buffer(data)
			collectgarbage("collect")
			local started = vim.uv.hrtime()
			if mode == "parse" then
				assert(buf)
				require("compile-mode.parser").parse(buf, 0, -1)
			else
				for _, line in ipairs(data) do
					assert(fast.captures(line, regex, rx))
				end
			end
			local elapsed = (vim.uv.hrtime() - started) / 1e6
			if iteration > 0 then
				rows[name][#rows[name] + 1] = elapsed
			end
			if buf then
				assert(vim.tbl_count(require("compile-mode.errors").error_list) == 10000)
				vim.api.nvim_buf_delete(buf, { force = true })
			end
			s.drain()
		end
	end
	results[mode] = rows
end
vim.fn.writefile({
	vim.json.encode({
		lines = 10000,
		baseline = vim.env.CAPTURES_BASELINE,
		other_runtime = "current worktree with candidate prefilters",
		samples = results,
	}),
}, "doc/measurements/canonical-captures-comparison.json")
vim.cmd("qa!")
