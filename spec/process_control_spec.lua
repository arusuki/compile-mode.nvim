local assert = require("luassert")
local helpers = require("spec.test_helpers")
local support = require("scripts.support")
local cm = require("compile-mode")
local input = require("compile-mode.input")

local function output()
	local b = vim.g.compilation_buffer
	return b and table.concat(vim.api.nvim_buf_get_lines(b, 4, -1, false), "\n") or ""
end

local function wait_for(text)
	assert.is_true(
		vim.wait(5000, function()
			return output():find(text, 1, true) ~= nil
		end, 5),
		output()
	)
end

local function start(extra, opts)
	helpers.setup_tests()
	support.setup(opts)
	vim.cmd("filetype plugin on")
	cm.compile({
		args = "python3 -u " .. vim.fn.shellescape(vim.fn.getcwd() .. "/spec/fixtures/interactive.py") .. (extra or ""),
		smods = { silent = true },
	})
	wait_for("prompt>")
	vim.api.nvim_set_current_buf(vim.g.compilation_buffer)
end

local function edit(text)
	local b = vim.g.compilation_buffer
	input.enter(b)
	vim.api.nvim_feedkeys("", "nx", false)
	vim.api.nvim_buf_set_lines(b, input.count(b), -1, false, { text })
end

local function finish()
	assert.is_true(vim.wait(5000, function()
		return vim.g.compilation_exit_code ~= nil
	end, 5))
end

describe("interactive process controls", function()
	after_each(function()
		cm.stop()
		support.drain()
	end)

	for _, pty in ipairs({ false, true }) do
		for _, newlines in ipairs({ 0, 1, 2 }) do
			it("reuses the prompt's empty tail with pty=" .. tostring(pty) .. ", newlines=" .. newlines, function()
				start(" --prompt-newlines " .. newlines, { use_pseudo_terminal = pty })
				local expected = { "prompt>" }
				for _ = 2, newlines do
					expected[#expected + 1] = ""
				end
				edit("one")
				expected[#expected + 1] = "one"
				assert.are.same(expected, vim.api.nvim_buf_get_lines(vim.g.compilation_buffer, 4, -1, false))
				vim.cmd.write()
				wait_for("received:one")
				-- Later output must also end immediately above the editable line.
				assert.is_nil(output():match("\n\n$"), output())
				edit("two")
				vim.cmd.write()
				wait_for("received:two")
				assert.is_truthy(output():find("received:two\n", 1, true))
				assert.is_nil(output():match("\n\n$"), output())
				edit("quit")
				vim.cmd.write()
				finish()
				assert.are.equal(0, vim.g.compilation_exit_code)
			end)
		end

		it("reuses a newline prompt for :w before Insert with pty=" .. tostring(pty), function()
			start(" --prompt-newlines 1", { use_pseudo_terminal = pty })
			vim.cmd.write()
			wait_for("received:")
			assert.is_truthy(output():find("prompt>\n> \n", 1, true))
			assert.is_true(cm.send_eof())
			finish()
		end)

		it("submits through :w and preserves output with pty=" .. tostring(pty), function()
			start("", { use_pseudo_terminal = pty })
			edit("hello")
			vim.cmd.write()
			wait_for("received:hello")
			assert.is_truthy(output():find("> hello", 1, true))
			edit("quit")
			vim.cmd.write()
			finish()
			assert.are.equal(0, vim.g.compilation_exit_code)
		end)

		it("delivers EOF with pty=" .. tostring(pty), function()
			start("", { use_pseudo_terminal = pty })
			assert.is_true(cm.send_eof())
			finish()
			assert.is_truthy(output():find("eof", 1, true))
		end)
	end

	it("sends an empty answer with :w before entering Insert mode", function()
		start()
		vim.cmd.write()
		wait_for("received:")
		assert.is_true(cm.send_eof())
		finish()
	end)

	it("rejects EOF while a draft exists and rejects closed stdin", function()
		start("", { use_pseudo_terminal = false })
		edit("keep")
		assert.is_false(cm.send_eof())
		vim.cmd.write()
		assert.is_true(cm.send_eof())
		assert.is_false(cm.send_eof())
		edit("unsent")
		assert.is_false(pcall(input.submit, vim.g.compilation_buffer))
		finish()
		assert.is_true(input.has_draft(vim.g.compilation_buffer))
	end)

	it("keeps the active session when discarding a draft is declined", function()
		start()
		edit("keep")
		local job = vim.g.compile_job_id
		local confirm = vim.fn.confirm
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.confirm = function()
			return 2
		end
		cm.compile({ args = "echo replacement", smods = { silent = true } })
		vim.fn.confirm = confirm
		assert.are.equal(job, vim.g.compile_job_id)
		assert.is_true(input.has_draft(vim.g.compilation_buffer))
		vim.cmd.write()
		wait_for("received:keep")
	end)

	it("reuses the compilation buffer without duplicating filetype handlers", function()
		start()
		edit("quit")
		vim.cmd.write()
		finish()
		local old_buf = vim.g.compilation_buffer
		cm.recompile({ smods = { silent = true } })
		assert.is_true(vim.wait(5000, function()
			return vim.g.compile_job_id ~= nil
		end, 5))
		wait_for("prompt>")
		assert.are.equal(old_buf, vim.g.compilation_buffer)
		edit("once")
		vim.cmd.write()
		wait_for("received:once")
		local _, count = output():gsub("received:once", "")
		assert.are.equal(1, count)
	end)

	if vim.fn.has("win32") == 0 then
		it("reports missing stty and allows opting out of PTY echo setup", function()
			helpers.setup_tests()
			support.setup({ use_pseudo_terminal = true })
			local exepath = vim.fn.exepath
			---@diagnostic disable-next-line: duplicate-set-field
			vim.fn.exepath = function(name)
				return name == "stty" and "" or exepath(name)
			end
			local ok, err = xpcall(function()
				local failed = support.compile("printf 'started\\n'")
				assert.are.equal(-1, failed.code)
				assert.is_truthy(output():find("requires stty", 1, true))
				assert.is_false(require("compile-mode.runner").is_busy())
				require("compile-mode.config.internal").pty_echo = true
				local finished = support.compile("printf 'started\\n'")
				assert.are.equal(0, finished.code)
				assert.are.same({ "started", "" }, vim.api.nvim_buf_get_lines(finished.bufnr, 4, -3, false))
			end, debug.traceback)
			vim.fn.exepath = exepath
			assert.is_true(ok, err)
		end)

		it("keeps shell commands, environment and exit status when disabling PTY echo", function()
			helpers.setup_tests()
			support.setup({
				use_pseudo_terminal = true,
				clear_environment = true,
				environment = { COMPILE_MODE_ECHO_TEST = "hello echo" },
			})
			local command = [[printf '%s\n' "$COMPILE_MODE_ECHO_TEST" | /usr/bin/tr '[:lower:]' '[:upper:]'; exit 7]]
			local ev = support.compile(command)
			assert.are.equal(7, ev.code)
			assert.are.equal(command, ev.command)
			assert.are.same({ "HELLO ECHO", "" }, vim.api.nvim_buf_get_lines(ev.bufnr, 4, -3, false))
		end)

		for _, echo in ipairs({ false, true }) do
			it("controls PTY echo for multiline input with pty_echo=" .. tostring(echo), function()
				start(" --prompt-newlines 1", { use_pseudo_terminal = true, pty_echo = echo })
				edit("123")
				local buf = vim.g.compilation_buffer
				vim.api.nvim_buf_set_lines(buf, input.count(buf), -1, false, { "123", "456", "789" })
				vim.cmd.write()
				wait_for("received:789")
				local lines = vim.api.nvim_buf_get_lines(buf, 4, -1, false)
				for _, value in ipairs({ "123", "456", "789" }) do
					local copies = 0
					for _, line in ipairs(lines) do
						if line == value then
							copies = copies + 1
						end
					end
					assert.are.equal(echo and 1 or 0, copies)
					assert.is_true(vim.tbl_contains(lines, "> " .. value))
					assert.is_true(vim.tbl_contains(lines, "received:" .. value))
				end
			end)
		end

		it("uses a PTY with echo disabled by default, including an empty answer", function()
			start(" --prompt-newlines 1")
			assert.is_string(vim.api.nvim_get_chan_info(vim.g.compile_job_id).pty)
			vim.cmd.write()
			wait_for("received:")
			assert.are.same(
				{ "prompt>", "> ", "received:", "" },
				vim.api.nvim_buf_get_lines(vim.g.compilation_buffer, 4, -1, false)
			)
		end)

		for _, extra in ipairs({ "--repeat-input", "--enable-echo" }) do
			it("preserves program output and terminal changes with " .. extra, function()
				start(" --prompt-newlines 1 " .. extra, { use_pseudo_terminal = true })
				edit("same text")
				vim.cmd.write()
				wait_for("received:same text")
				assert.are.same(
					{ "prompt>", "> same text", "same text", "received:same text", "" },
					vim.api.nvim_buf_get_lines(vim.g.compilation_buffer, 4, -1, false)
				)
			end)
		end

		for _, pty in ipairs({ false, true }) do
			it("inserts asynchronous output directly above an unsent draft with pty=" .. tostring(pty), function()
				start(" --prompt-newlines 1", { use_pseudo_terminal = pty })
				edit("keep")
				vim.api.nvim_win_set_cursor(0, { input.count(vim.g.compilation_buffer) + 1, 2 })
				assert.is_true(cm.signal("USR1"))
				wait_for("signal:SIGUSR1")
				assert.are.same(
					{ "prompt>", "signal:SIGUSR1", "keep" },
					vim.api.nvim_buf_get_lines(vim.g.compilation_buffer, 4, -1, false)
				)
				assert.are.same({ 7, 2 }, vim.api.nvim_win_get_cursor(0))
				vim.cmd.write()
				wait_for("received:keep")
			end)
		end

		it("keeps a signal-catching process alive and accepts names and numbers", function()
			start()
			local job = vim.g.compile_job_id
			assert.is_false(cm.signal("NOT_A_SIGNAL"))
			assert.is_true(cm.interrupt())
			wait_for("signal:SIGINT")
			assert.are.equal(job, vim.g.compile_job_id)
			assert.is_true(cm.signal("SIGUSR1"))
			wait_for("signal:SIGUSR1")
			assert.is_true(cm.signal(vim.uv.constants.SIGQUIT))
			wait_for("signal:SIGQUIT")
			edit("quit")
			vim.cmd.write()
			finish()
			assert.is_false(cm.interrupt())
		end)

		it("signals children in the compilation process group", function()
			start(" --child")
			wait_for("child:ready")
			assert.is_true(cm.signal("USR1"))
			wait_for("child:USR1")
			wait_for("signal:SIGUSR1")
			edit("quit")
			vim.cmd.write()
			finish()
		end)

		it("pauses and resumes before accepting further input", function()
			start()
			assert.is_true(cm.signal("STOP"))
			edit("after-stop")
			vim.cmd.write()
			assert.is_false(vim.wait(100, function()
				return output():find("received:after-stop", 1, true) ~= nil
			end, 5))
			assert.is_true(cm.signal("CONT"))
			wait_for("received:after-stop")
			assert.is_true(cm.signal("TERM"))
			finish()
			assert.are_not.equal(0, vim.g.compilation_exit_code)
		end)

		it("kills the process and completes the normal lifecycle", function()
			start()
			assert.is_true(cm.signal("KILL"))
			finish()
			assert.are_not.equal(0, vim.g.compilation_exit_code)
		end)
	end
end)
