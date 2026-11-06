local s = require("scripts.support")
s.setup()
local upstream = vim.env.BENCH_UPSTREAM == "1"
local input = vim.fn.readfile(vim.env.BENCH_INPUT)
local mode = vim.env.BENCH_MODE
local rows = {}
local last_records
for iteration = 0, tonumber(vim.env.BENCH_SAMPLES) do
	if upstream then
		require("compile-mode.errors").error_list = {}
		require("compile-mode.dir").dir_changes = {}
	else
		require("compile-mode.state").reset()
	end
	local buf = mode == "parse" and s.buffer(input) or nil
	collectgarbage("collect")
	local last = vim.uv.hrtime()
	local gap = 0
	local timer
	if mode ~= "parse" then
		timer = assert(vim.uv.new_timer())
		timer:start(
			5,
			5,
			vim.schedule_wrap(function()
				local now = vim.uv.hrtime()
				gap = math.max(gap, (now - last) / 1e6)
				last = now
			end)
		)
	end
	local started = vim.uv.hrtime()
	if mode == "parse" then
		assert(buf)
		if upstream then
			require("compile-mode")._parse_errors(buf, 0, -1)
		else
			require("compile-mode.parser").parse(buf, 0, -1)
		end
	else
		local ev = s.compile("cat " .. vim.fn.shellescape(vim.env.BENCH_INPUT), nil, iteration > 0)
		assert(ev.code == 0)
		buf = ev.bufnr
	end
	local elapsed = (vim.uv.hrtime() - started) / 1e6
	gap = math.max(gap, (vim.uv.hrtime() - last) / 1e6)
	if timer then
		timer:stop()
		timer:close()
	end
	assert(buf)
	local output = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	assert(output:find(table.concat(input, "\n"), 1, true), "output changed")
	local errors = require("compile-mode.errors").error_list
	last_records = {}
	for _, line in ipairs(vim.fn.sort(vim.tbl_keys(errors), "n")) do
		last_records[#last_records + 1] = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
	end
	if iteration > 0 then
		rows[#rows + 1] = { ms = elapsed, gap_ms = gap, recognized = vim.tbl_count(errors) }
	end
	if mode == "parse" then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	s.drain()
end
vim.fn.writefile(last_records, vim.env.BENCH_RESULT .. ".records")
vim.fn.writefile({ vim.json.encode({ editor = vim.version(), mode = mode, samples = rows }) }, vim.env.BENCH_RESULT)
vim.cmd("qa!")
