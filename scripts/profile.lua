-- Sample real Lua/C call stacks. Timing comparisons belong in benchmark.lua:
-- the sampling callback and stack collection add overhead to this run.
local s = require("scripts.support")
local profile = require("jit.profile")
local kind = arg[1] or "plain"
local count = tonumber(arg[2]) or 10000
local repetitions = tonumber(arg[3]) or 5
s.setup({ ansi_color = { kind = kind == "ansi" and "render" or "filter", baleia_options = {} } })
local parser = require("compile-mode.parser")
local data = {}
local command
if kind == "ansi" then
	command = s.command("scripts/producer.lua", "ansi", tostring(count))
elseif kind == "log" then
	data = vim.fn.readfile(assert(vim.env.PROFILE_LOG, "PROFILE_LOG is required"))
	count = #data
else
	for i = 1, count do
		data[i] = (kind == "errors" or kind == "incremental") and ("file.c:%d:1: error: failure"):format(i)
			or kind == "long" and string.rep("x", 4096)
			or ("build step %d complete"):format(i)
	end
end
local stacks, states = {}, {}
local total = 0
local started = vim.uv.hrtime()
local ok, err = xpcall(function()
	for run = 1, repetitions do
		require("compile-mode.state").reset()
		local buf = not command and s.buffer(data) or nil
		collectgarbage("collect")
		profile.start("li1", function(thread, samples, state)
			local stack = profile.dumpstack(thread, "plZ;", 12)
			stacks[stack] = (stacks[stack] or 0) + samples
			states[state] = (states[state] or 0) + samples
			total = total + samples
		end)
		if command then
			local ev = s.compile(command, nil, run > 1)
			s.equal(0, ev.code)
			s.equal(count + 7, vim.api.nvim_buf_line_count(ev.bufnr))
		elseif kind == "incremental" then
			assert(buf)
			for i = 0, count - 1 do
				parser.parse(buf, i, i + 1)
			end
		else
			assert(buf)
			parser.parse(buf, 0, -1)
		end
		profile.stop()
		s.drain()
		if buf then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end, debug.traceback)
profile.stop()
local ranked = {}
for stack, samples in pairs(stacks) do
	ranked[#ranked + 1] = { stack = stack, samples = samples, percent = 100 * samples / total }
end
table.sort(ranked, function(a, b)
	return a.samples > b.samples
end)
s.finish({
	name = kind,
	passed = ok,
	error = not ok and err or nil,
	lines = count,
	repetitions = repetitions,
	interval_ms = 1,
	samples = total,
	vm_states = states,
	stacks = ranked,
	wall_ms_including_preparation = (vim.uv.hrtime() - started) / 1e6,
	nvim = vim.version(),
	jit = jit.version,
})
