-- Diagnostic harness: instrumentation changes timings; controls run separately.
local support = require("scripts.support")
support.setup()
local count = tonumber(vim.env.AUDIT_LINES) or 10000
local samples = tonumber(vim.env.AUDIT_SAMPLES) or 7
local variant = vim.env.AUDIT_VARIANT or "baseline"
local instrument = vim.env.AUDIT_TRACE == "1"
local hrtime = vim.uv.hrtime
local active, origin, phase, events
local function now()
	return (hrtime() - origin) / 1e6
end
local function wrap(object, name, label)
	local original = object[name]
	object[name] = function(...)
		if not active then
			return original(...)
		end
		local start, p = now(), phase
		local result = { original(...) }
		local finish = now()
		if finish - start >= 0.1 then
			events[#events + 1] = { name = label or name, start = start, finish = finish, phase = p }
		end
		return unpack(result)
	end
end
if instrument then
	for module, names in pairs({
		["compile-mode.parser"] = { "parse" },
		["compile-mode.ansi"] = { "buf_set_lines", "reset" },
		["compile-mode.utils"] = { "clear_highlights", "clear_diagnostics" },
		["compile-mode.state"] = { "reset" },
	}) do
		for _, name in ipairs(names) do
			wrap(require(module), name, module .. "." .. name)
		end
	end
	wrap(vim.api, "nvim_buf_set_lines")
	wrap(vim.api, "nvim_buf_clear_namespace")
	local schedule = vim.schedule
	---@diagnostic disable-next-line: duplicate-set-field -- Isolated experimental control.
	vim.schedule = function(fn)
		local info = debug.getinfo(fn, "Sl")
		local label = (info.short_src or "?") .. ":" .. info.linedefined
		return schedule(function()
			if not active then
				return fn()
			end
			local start, p = now(), phase
			fn()
			local finish = now()
			if finish - start >= 0.1 then
				events[#events + 1] = { name = "scheduled:" .. label, start = start, finish = finish, phase = p }
			end
		end)
	end
end
if variant == "no_marks" then
	---@diagnostic disable-next-line: duplicate-set-field -- Isolated experimental control.
	require("compile-mode.errors").highlight = function() end
end
if variant == "clear_chunks" then
	local utils = require("compile-mode.utils")
	local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
	---@diagnostic disable-next-line: duplicate-set-field -- Isolated experimental control.
	utils.clear_highlights = function(buf, owned)
		local total = vim.api.nvim_buf_line_count(buf)
		for first = 0, total - 1, 256 do
			if owned and not owned() then
				return false
			end
			vim.api.nvim_buf_clear_namespace(buf, ns, first, math.min(first + 256, total))
			if first + 256 < total then
				utils.delay(0)
			end
		end
		return true
	end
end
if variant == "timer1" then
	local defer = vim.defer_fn
	---@diagnostic disable-next-line: duplicate-set-field -- Isolated experimental control.
	vim.defer_fn = function(fn, timeout)
		return defer(fn, timeout == 0 and 1 or timeout)
	end
end
local jobstart = vim.fn.jobstart
vim.fn.jobstart = function(...)
	if active then
		phase = "stream"
	end
	return jobstart(...)
end
local input = {}
for i = 1, count do
	input[i] = ("file.c:%d:1: error: failure"):format(i)
end
local path = vim.fn.tempname()
vim.fn.writefile(input, path)
local rows = {}
for iteration = 0, samples do
	local cleanup_start = hrtime()
	if variant == "fresh" and vim.g.compilation_buffer and vim.api.nvim_buf_is_valid(vim.g.compilation_buffer) then
		vim.api.nvim_buf_delete(vim.g.compilation_buffer, { force = true })
		vim.g.compilation_buffer = nil
		support.drain()
	end
	local cleanup_ms = (hrtime() - cleanup_start) / 1e6
	require("compile-mode.state").reset()
	collectgarbage("collect")
	if variant == "no_gc" then
		collectgarbage("stop")
	end
	origin = hrtime()
	phase = "setup"
	events = {}
	active = true
	local raw, scheduled = {}, {}
	local last_raw, last_scheduled = 0, 0
	local timer = assert(vim.uv.new_timer())
	timer:start(5, 5, function()
		if not active then
			return
		end
		local t, p = now(), phase
		raw[#raw + 1] = { start = last_raw, finish = t, gap = t - last_raw, phase = p }
		last_raw = t
		vim.schedule(function()
			if not active then
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
	local completed
	local autocmd = vim.api.nvim_create_autocmd("User", {
		pattern = "CompilationFinished",
		once = true,
		callback = function()
			completed = now()
			phase = "finish"
		end,
	})
	local ev = support.compile("cat " .. vim.fn.shellescape(path), nil, iteration > 0)
	local elapsed = now()
	active = false
	timer:stop()
	timer:close()
	collectgarbage("restart")
	assert(ev.code == 0)
	assert(vim.tbl_count(require("compile-mode.errors").error_list) == count)
	assert(
		#vim.api.nvim_buf_get_extmarks(ev.bufnr, vim.api.nvim_create_namespace("compile-mode.nvim"), 0, -1, {})
			== (variant == "no_marks" and 0 or count * 4)
	)
	local output = table.concat(vim.api.nvim_buf_get_lines(ev.bufnr, 0, -1, false), "\n")
	assert(output:find(table.concat(input, "\n"), 1, true))
	raw[#raw + 1] = { start = last_raw, finish = elapsed, gap = elapsed - last_raw, phase = "finish" }
	scheduled[#scheduled + 1] =
		{ start = last_scheduled, finish = elapsed, gap = elapsed - last_scheduled, queue_ms = 0, phase = "finish" }
	if iteration > 0 then
		rows[#rows + 1] = {
			ms = elapsed,
			preparation_cleanup_ms = cleanup_ms,
			completed_ms = completed,
			raw = raw,
			scheduled = scheduled,
			events = events,
		}
	end
	support.drain()
end
vim.fn.delete(path)
vim.fn.writefile(
	{ vim.json.encode({ variant = variant, lines = count, instrumented = instrument, samples = rows }) },
	assert(vim.env.AUDIT_RESULT)
)
vim.cmd("qa!")
