local M = {}

function M.setup(opts)
	vim.g.compile_mode = vim.tbl_extend("force", {
		ask_about_save = false,
		ask_to_interrupt = false,
		auto_scroll = false,
		error_locus_highlight = false,
		ansi_color = { kind = "filter" },
		ansi_osc = { kind = "filter" },
	}, opts or {})
	local cm = require("compile-mode")
	require("plugin.command")
	require("compile-mode.dir").compilation_directory = vim.fn.getcwd()
	return cm, require("compile-mode.config.internal")
end

function M.equal(expected, actual, label)
	assert(
		vim.deep_equal(expected, actual),
		(label or "value") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
	)
end

function M.buffer(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

function M.drain()
	local done = false
	vim.schedule(function()
		vim.schedule(function()
			done = true
		end)
	end)
	assert(
		vim.wait(5000, function()
			return done
		end, 1),
		"scheduled work did not drain"
	)
end

function M.compile(command, inspect_running, recompile)
	local finished
	local event = vim.api.nvim_create_autocmd("User", {
		once = true,
		pattern = "CompilationFinished",
		callback = function(ev)
			finished = ev.data
		end,
	})
	local started = vim.uv.hrtime()
	local cm = require("compile-mode")
	local launch = recompile and cm.recompile or cm.compile
	launch({ args = command, smods = { silent = true } })
	local ok, err = pcall(function()
		if inspect_running then
			inspect_running()
		end
		assert(
			vim.wait(15000, function()
				return finished ~= nil
			end, 1),
			"CompilationFinished timeout"
		)
	end)
	if not ok then
		pcall(vim.api.nvim_del_autocmd, event)
		if vim.g.compile_job_id then
			vim.fn.jobstop(vim.g.compile_job_id)
		end
		error(err)
	end
	local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
	M.drain()
	return finished, elapsed_ms
end

function M.command(script, ...)
	local args = { vim.v.progpath, "--headless", "--clean", "-l", script, ... }
	return table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
end

function M.measure(name, units, prepare, operation, verify, samples)
	local times = {}
	local retained = {}
	for i = 1, (samples or 7) + 1 do
		local context = prepare()
		collectgarbage("collect")
		local memory_before = collectgarbage("count")
		local started = vim.uv.hrtime()
		local result = operation(context)
		local elapsed = (vim.uv.hrtime() - started) / 1e6
		if verify then
			verify(context, result)
		end
		collectgarbage("collect")
		if i > 1 then
			times[#times + 1] = elapsed
			retained[#retained + 1] = collectgarbage("count") - memory_before
		end
		M.drain()
		if context.buf then
			vim.api.nvim_buf_delete(context.buf, { force = true })
		end
	end
	local sorted = vim.deepcopy(times)
	table.sort(sorted)
	return {
		name = name,
		units = units,
		samples_ms = times,
		median_ms = sorted[math.ceil(#sorted / 2)],
		p95_ms = sorted[math.ceil(#sorted * 0.95)],
		retained_lua_kib = retained,
	}
end

function M.finish(result)
	local destination = assert(vim.env.COMPILE_MODE_RESULT, "COMPILE_MODE_RESULT is required")
	vim.fn.writefile({ vim.json.encode(result) }, destination)
	vim.cmd("qa!")
end

return M
