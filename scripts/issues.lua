-- Standalone assertions of desired behavior. Known failures stay failures.
local s = require("scripts.support")
local cases = {}

cases.directory_quickfix = function()
	s.setup()
	local dir = require("compile-mode.dir")
	local errors = require("compile-mode.errors")
	dir.compilation_directory = vim.fn.getcwd()
	local buf = s.buffer({
		"header",
		"started",
		"",
		"make",
		"make: Entering directory 'build'",
		"main.c:1:2: error: failed",
		"make: Leaving directory 'build'",
	})
	require("compile-mode.parser").scan(buf, 4, -1)
	local qf = errors.toqflist(errors.error_list)
	s.equal(dir.compilation_directory .. "/build/main.c", qf[1].filename, "quickfix path for source row 1/output row 6")
end

cases.directory_diagnostics = function()
	s.setup()
	local dir = require("compile-mode.dir")
	local errors = require("compile-mode.errors")
	dir.compilation_directory = vim.fn.getcwd()
	dir.dir_changes = { [5] = dir.compilation_directory .. "/build", [8] = dir.compilation_directory }
	local error = assert(errors.parse("main.c:1:2: error: failed", 6))
	local target = vim.fn.bufadd(dir.compilation_directory .. "/build/main.c")
	s.equal(1, #errors.todiagnostic(target, { [6] = error }), "diagnostics in the resolved source buffer")
end

for _, mode in ipairs({ "filter", "render" }) do
	cases["scroll_" .. mode] = function()
		s.setup({ auto_scroll = true, ansi_color = { kind = mode, baleia_options = {} } })
		if mode == "render" then
			assert(pcall(require, "baleia"), "baleia is required")
		end
		s.compile(s.command("scripts/producer.lua", "stream", "100"), function()
			assert(
				vim.wait(5000, function()
					local buf = vim.g.compilation_buffer
					return buf and vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "READY")
				end, 1),
				"stream did not produce READY"
			)
			s.drain()
			assert(vim.g.compile_job_id, "must inspect while the job is still running")
			local buf = vim.g.compilation_buffer
			local win = vim.fn.win_findbuf(buf)[1]
			s.equal(vim.api.nvim_buf_line_count(buf), vim.api.nvim_win_get_cursor(win)[1], "live output cursor")
		end)
	end
end

cases.nul_streams = function()
	s.setup()
	local ev = s.compile(s.command("scripts/producer.lua", "nul"))
	local lines = vim.api.nvim_buf_get_lines(ev.bufnr, 4, -1, false)
	assert(vim.tbl_contains(lines, "output"), "stdout NUL was not removed")
	assert(vim.tbl_contains(lines, "error"), "stderr NUL was not removed")
	s.equal(0, ev.code)
end

cases.ansi_cargo = function()
	s.setup({ ansi_color = { kind = "render", baleia_options = {} } })
	assert(pcall(require, "baleia"), "baleia is required")
	local ev = s.compile(s.command("scripts/producer.lua", "mixed"))
	local lines = vim.api.nvim_buf_get_lines(ev.bufnr, 4, -1, false)
	assert(vim.tbl_contains(lines, "compiler"), "compiler stderr text missing")
	assert(vim.tbl_contains(lines, "program"), "program stdout text missing")
	assert(not table.concat(lines):find("\27", 1, true), "escape bytes leaked")
	-- Do not require ordering across separate OS pipes (#76 discussion).
end

cases.ansi_underline = function()
	s.setup({ ansi_color = { kind = "render", baleia_options = {} } })
	assert(pcall(require, "baleia"), "baleia is required")
	local buf = s.buffer({ "" })
	require("compile-mode.ansi").buf_set_lines(buf, 0, -1, { "\27[4munderlined\27[0m" })
	s.drain()
	s.equal({ "underlined" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	local underline = false
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
		local group = mark[4].hl_group
		if group and vim.api.nvim_get_hl(0, { name = group, link = false }).underline then
			underline = true
		end
	end
	assert(underline, "SGR 4 has no underline highlight")
end

cases.matcher_priority = function()
	s.setup({
		error_regexp_table = {
			zig = {
				regex = [[^\s*\(.\{-}\):\([0-9]\+\):\([0-9]\+\):]],
				filename = 1,
				row = 2,
				col = 3,
				priority = 2,
			},
		},
	})
	local error = assert(require("compile-mode.errors").parse("main.zig:12:3: error: mismatch", 6))
	s.equal("zig", error.group)
	s.equal(12, error.row.value)
	s.equal(3, error.col.value)
end

cases.quickfix_threshold = function()
	local cm = s.setup()
	local errors = require("compile-mode.errors")
	local messages = {
		"main.c:12:9: error: too few arguments",
		"main.c:13:9: warning: unused variable",
		"render.h:17:6: note: declared here",
	}
	local parsed = {}
	for i, line in ipairs(messages) do
		parsed[i] = assert(errors.parse(line, i))
	end
	s.equal(cm.level.INFO, parsed[3].level)
	s.equal(2, #errors.toqflist(parsed), "warning threshold excludes notes")
end

cases.max_lines = function()
	s.setup({ max_lines = 100 })
	local ev = s.compile(s.command("scripts/producer.lua", "plain", "10000"))
	s.equal(143, ev.code, "line limit exit code")
	local lines = vim.api.nvim_buf_get_lines(ev.bufnr, 0, -1, false)
	assert(#lines <= 106, "header + budget + footer exceeded")
	assert(table.concat(lines, "\n"):find("max_lines reached", 1, true), "missing limit message")
end

cases.window_reuse = function()
	local cm = s.setup()
	vim.cmd("edit README.md")
	local source_win = vim.api.nvim_get_current_win()
	local compilation = s.buffer({ "README.md, line 1, char 1:" })
	vim.cmd("split")
	vim.api.nvim_set_current_buf(compilation)
	vim.g.compilation_buffer = compilation
	require("compile-mode.parser").parse(compilation, 0, -1)
	local windows = #vim.api.nvim_list_wins()
	cm.goto_error({ smods = { silent = true } })
	s.drain()
	s.equal(windows, #vim.api.nvim_list_wins(), "window count")
	s.equal(source_win, vim.api.nvim_get_current_win(), "existing source window")
end

cases.highlight_scope = function()
	s.setup()
	local source = s.buffer({ "# Markdown", "Code example: cd doc/ && echo hi" })
	vim.api.nvim_set_current_buf(source)
	local source_win = vim.api.nvim_get_current_win()
	local command = s.command("scripts/producer.lua", "plain", "1")
	local ev = s.compile(command)
	vim.api.nvim_set_current_win(source_win)
	vim.api.nvim_set_current_buf(ev.bufnr)
	s.compile(command, nil, true)
	vim.api.nvim_set_current_win(source_win)
	vim.api.nvim_set_current_buf(source)
	local leaking = vim.tbl_filter(function(match)
		return match.group == "CompileModeDirectoryMessage"
	end, vim.fn.getmatches())
	s.equal(0, #leaking, "compilation-only window matches in a source buffer")
end

-- A related incremental-output invariant discovered while examining #119/#160.
cases.reparse_extmarks = function()
	s.setup()
	local buf = s.buffer({ "main.c:12:3: error: failure" })
	local parser = require("compile-mode.parser")
	local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
	parser.parse(buf, 0, -1)
	local before = #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
	for _ = 1, 20 do
		parser.parse(buf, 0, -1)
	end
	local after = #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
	s.equal(before, after, "extmarks after unchanged range rescans")
end

cases.reparse_stale_error = function()
	s.setup()
	local buf = s.buffer({ "main.c:12:3: error: failure" })
	local parser = require("compile-mode.parser")
	parser.parse(buf, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "build succeeded" })
	parser.parse(buf, 0, -1)
	s.equal(nil, require("compile-mode.errors").error_list[1], "obsolete error after line replacement")
end

cases.ansi_recompile_extmarks = function()
	s.setup({ ansi_color = { kind = "render", baleia_options = {} } })
	assert(pcall(require, "baleia"), "baleia is required")
	local command = s.command("scripts/producer.lua", "ansi", "100")
	local ev = s.compile(command)
	local before = #vim.api.nvim_buf_get_extmarks(ev.bufnr, -1, 0, -1, {})
	ev = s.compile(command, nil, true)
	local after = #vim.api.nvim_buf_get_extmarks(ev.bufnr, -1, 0, -1, {})
	s.equal(before, after, "ANSI extmarks after identical recompilation")
end

-- Guard against the single-matcher shortcut discussed in PR #62.
cases.mixed_matcher_languages = function()
	s.setup()
	local errors = require("compile-mode.errors")
	for i, item in ipairs({
		{ "main.c:12:3: error: failure", "main.c", 12, "gnu" },
		{ '  File "module.py", line 2', "module.py", 2, "python_tracebacks_and_caml" },
		{ "CMake Error at CMakeLists.txt:5 (add_executable):", "CMakeLists.txt", 5, "cmake" },
	}) do
		local error = assert(errors.parse(item[1], i))
		s.equal(item[2], error.filename.value)
		s.equal(item[3], error.row.value)
		s.equal(item[4], error.group)
	end
end

local name = arg[1]
if name == "list" then
	s.finish(vim.tbl_keys(cases))
else
	local ok, err = xpcall(assert(cases[name], "unknown case: " .. tostring(name)), debug.traceback)
	s.finish({ name = name, passed = ok, error = not ok and err or nil })
end
