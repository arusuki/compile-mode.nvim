-- Diagnostic instrumentation only; wrapper overhead changes timings.
-- Use run_emacs_bench.py for uninstrumented performance comparisons.
local original = vim.regex
local stats = {}
---@diagnostic disable-next-line: duplicate-set-field -- Instrument the native matcher factory.
vim.regex = function(pattern)
	local rx = original(pattern)
	local row = stats[pattern] or { calls = 0, hits = 0, ms = 0 }
	stats[pattern] = row
	return {
		match_str = function(_, line)
			local t = vim.uv.hrtime()
			local a, b = rx:match_str(line)
			row.ms = row.ms + (vim.uv.hrtime() - t) / 1e6
			row.calls = row.calls + 1
			if a then
				row.hits = row.hits + 1
			end
			return a, b
		end,
	}
end
local s = require("scripts.support")
s.setup()
local data = {}
for i = 1, 10000 do
	data[i] = ("file.c:%d:1: error: failure"):format(i)
end
for run = 1, 12 do
	require("compile-mode.state").reset()
	local buf = s.buffer(data)
	collectgarbage("collect")
	require("compile-mode.parser").parse(buf, 0, -1)
	assert(vim.tbl_count(require("compile-mode.errors").error_list) == 10000)
	vim.api.nvim_buf_delete(buf, { force = true })
	s.drain()
end
local labels = {}
for label, matcher in pairs(require("compile-mode.config.internal").error_regexp_table) do
	labels[matcher.regex] = label
end
local rows = {}
for pattern, row in pairs(stats) do
	row.matcher = labels[pattern] or pattern
	rows[#rows + 1] = row
end
table.sort(rows, function(a, b)
	return a.ms > b.ms
end)
vim.fn.writefile(
	{ vim.json.encode({ repetitions = 12, lines = 10000, instrumented = true, matchers = rows }) },
	"doc/measurements/three-way-regex-errors.json"
)
vim.cmd("qa!")
