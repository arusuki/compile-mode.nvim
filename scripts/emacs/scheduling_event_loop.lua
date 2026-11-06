-- Run with :luafile, not -l: use Neovim's ordinary event loop, without vim.wait.
local support = require("scripts.support")
local cm = support.setup()
local count = tonumber(vim.env.AUDIT_LINES) or 10000
local samples = tonumber(vim.env.AUDIT_SAMPLES) or 5
local input = {}
for i = 1, count do
	input[i] = ("file.c:%d:1: error: failure"):format(i)
end
local path = vim.fn.tempname()
vim.fn.writefile(input, path)
local results = {}
local iteration = 0
local origin, phase, timer, raw, scheduled, last_raw, last_scheduled
local function now()
	return (vim.uv.hrtime() - origin) / 1e6
end
local jobstart = vim.fn.jobstart
vim.fn.jobstart = function(...)
	phase = "stream"
	return jobstart(...)
end
local function launch()
	require("compile-mode.state").reset()
	collectgarbage("collect")
	phase = "setup"
	raw = {}
	scheduled = {}
	last_raw = 0
	last_scheduled = 0
	origin = vim.uv.hrtime()
	local generation = iteration
	timer = assert(vim.uv.new_timer())
	timer:start(5, 5, function()
		local t = now()
		raw[#raw + 1] = { start = last_raw, finish = t, gap = t - last_raw, phase = phase }
		last_raw = t
		vim.schedule(function()
			if iteration ~= generation then
				return
			end
			local arrived = now()
			scheduled[#scheduled + 1] = {
				start = last_scheduled,
				finish = arrived,
				gap = arrived - last_scheduled,
				queue_ms = arrived - t,
				phase = phase,
			}
			last_scheduled = arrived
		end)
	end)
	local command = iteration > 0 and cm.recompile or cm.compile
	command({ args = "cat " .. vim.fn.shellescape(path), smods = { silent = true } })
end
vim.api.nvim_create_autocmd("User", {
	pattern = "CompilationFinished",
	callback = function(ev)
		local elapsed = now()
		timer:stop()
		timer:close()
		raw[#raw + 1] = { start = last_raw, finish = elapsed, gap = elapsed - last_raw, phase = "finish" }
		scheduled[#scheduled + 1] =
			{ start = last_scheduled, finish = elapsed, gap = elapsed - last_scheduled, queue_ms = 0, phase = "finish" }
		assert(ev.data.code == 0)
		assert(vim.tbl_count(require("compile-mode.errors").error_list) == count)
		assert(
			#vim.api.nvim_buf_get_extmarks(
					ev.data.bufnr,
					vim.api.nvim_create_namespace("compile-mode.nvim"),
					0,
					-1,
					{}
				) == count * 4
		)
		assert(
			table
				.concat(vim.api.nvim_buf_get_lines(ev.data.bufnr, 0, -1, false), "\n")
				:find(table.concat(input, "\n"), 1, true)
		)
		if iteration > 0 then
			results[#results + 1] = {
				ms = elapsed,
				completed_ms = elapsed,
				preparation_cleanup_ms = 0,
				raw = raw,
				scheduled = scheduled,
				events = {},
			}
		end
		iteration = iteration + 1
		if iteration > samples then
			vim.fn.delete(path)
			vim.fn.writefile(
				{ vim.json.encode({ variant = "event_loop", instrumented = false, lines = count, samples = results }) },
				assert(vim.env.AUDIT_RESULT)
			)
			vim.schedule(function()
				vim.cmd("qa!")
			end)
		else
			vim.defer_fn(launch, 10)
		end
	end,
})
vim.schedule(launch)
