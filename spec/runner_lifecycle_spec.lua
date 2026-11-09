---@diagnostic disable: duplicate-set-field -- Test doubles are restored after each case.
local assert = require("luassert")
local helpers = require("spec.test_helpers")
local s = require("scripts.support")
local runner = require("compile-mode.runner")
local errors = require("compile-mode.errors")
local parser = require("compile-mode.parser")

local jobstart, jobstop, parse, tmpfile, notify, confirm

describe("compilation session ownership and recovery", function()
	before_each(function()
		helpers.setup_tests()
		s.setup()
		jobstart, jobstop, parse, tmpfile, notify =
			vim.fn.jobstart, vim.fn.jobstop, parser.parse, io.tmpfile, vim.notify
	end)

	after_each(function()
		vim.fn.jobstart, vim.fn.jobstop, parser.parse, io.tmpfile, vim.notify =
			jobstart, jobstop, parse, tmpfile, notify
	end)

	it("supersedes a pending setup before starting its subprocess", function()
		-- Compare the original commands without PTY initialization commands.
		require("compile-mode.config.internal").use_pseudo_terminal = false
		local launched, finished = {}, {}
		vim.fn.jobstart = function(command, opts)
			launched[#launched + 1] = command
			vim.schedule(function()
				opts.on_stdout(101, { command, "" })
				opts.on_exit(101, 0)
			end)
			return 101
		end
		local event = vim.api.nvim_create_autocmd("User", {
			pattern = "CompilationFinished",
			callback = function(ev)
				finished[#finished + 1] = ev.data.command
			end,
		})
		local cm = require("compile-mode")
		cm.compile({ args = "obsolete", smods = { silent = true } })
		local ev = s.compile("replacement")
		vim.api.nvim_del_autocmd(event)
		assert.are.same({ "replacement" }, launched)
		assert.are.same({ "replacement" }, finished)
		assert.are.equal("replacement", vim.api.nvim_buf_get_lines(ev.bufnr, 3, 4, false)[1])
		assert.are.equal(8, vim.api.nvim_buf_line_count(ev.bufnr))
		assert.is_false(runner.is_busy())
	end)

	for _, failure in ipairs({ "negative", "zero", "exception" }) do
		it("publishes a failed completion and releases ownership for " .. failure .. " jobstart", function()
			vim.fn.jobstart = function()
				if failure == "exception" then
					error("cannot spawn")
				end
				return failure == "zero" and 0 or -1
			end
			local ev = s.compile("invalid command")
			assert.are.equal(-1, ev.code)
			assert.are.equal(-1, vim.g.compilation_exit_code)
			assert.is_nil(vim.g.compile_job_id)
			assert.is_false(runner.is_busy())
			assert.is_truthy(vim.api.nvim_buf_get_lines(ev.bufnr, -3, -2, false)[1]:match("^Compilation failed:"))
		end)
	end

	it("keeps the accepted command and directory when an interruption is declined", function()
		local cm = require("compile-mode")
		local dir = require("compile-mode.dir")
		local config = require("compile-mode.config.internal")
		vim.fn.jobstart = function()
			return 101
		end
		vim.fn.jobstop = function()
			return 1
		end
		vim.g.compilation_directory = "/tmp/accepted"
		cm.compile({ args = "accepted", smods = { silent = true } })
		assert.is_true(vim.wait(1000, function()
			return vim.g.compile_job_id == 101
		end, 1))
		config.ask_to_interrupt = true
		vim.fn.confirm = function()
			return 2
		end
		vim.g.compilation_directory = "/tmp/rejected"
		cm.compile({ args = "rejected", smods = { silent = true } })
		assert.are.equal("accepted", vim.g.compile_command)
		assert.are.equal("/tmp/accepted", dir.compilation_directory)
		assert.are.equal(101, vim.g.compile_job_id)
		runner.stop()
		s.drain()
	end)

	it("stops remaining parse slices after a synchronous interruption", function()
		local scans, interrupted = 0, false
		parser.parse = function(buf, first, last)
			parse(buf, first, last)
			if first >= 4 then
				scans = scans + 1
				runner.stop()
			end
		end
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				local data = {}
				for i = 1, 128 do
					data[i] = "f.c:1:1: error: stop"
				end
				data[#data + 1] = ""
				opts.on_stdout(101, data)
			end)
			return 101
		end
		vim.fn.jobstop = function()
			return 1
		end
		vim.api.nvim_create_autocmd("User", {
			once = true,
			pattern = "CompilationInterrupted",
			callback = function()
				interrupted = true
			end,
		})
		require("compile-mode").compile({ args = "interrupt parser", smods = { silent = true } })
		assert.is_true(vim.wait(1000, function()
			return interrupted
		end, 1))
		s.drain()
		assert.are.equal(1, scans)
		assert.is_false(runner.is_busy())
	end)

	it("keeps stdout and stderr partial lines separate when revisiting an earlier row", function()
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				opts.on_stdout(101, { "out-prefix" })
				opts.on_stderr(101, { "err.c:1:2: error: failure", "" })
				opts.on_stdout(101, { "suffix", "last", "" })
				opts.on_exit(101, 0)
			end)
			return 101
		end
		local ev = s.compile("mixed streams")
		assert.are.same(
			{ "out-prefixsuffix", "err.c:1:2: error: failure", "last", "" },
			vim.api.nvim_buf_get_lines(ev.bufnr, 4, -3, false)
		)
		assert.are.equal("err.c", errors.error_list[6].filename.value)
	end)

	it("services timers before an already queued output burst finishes", function()
		local total, observed = 20000, false
		local timer
		parser.parse = function(buf, first, last)
			parse(buf, first, last)
			if first >= 4 and not timer then
				timer = vim.defer_fn(function()
					local count = errors.counts().error
					observed = count > 0 and count < total
				end, 3)
			end
		end
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				local data = {}
				for i = 1, total do
					data[i] = "file.c:" .. i .. ":1: error: failure"
				end
				data[#data + 1] = ""
				opts.on_stdout(101, data)
				opts.on_exit(101, 0)
			end)
			return 101
		end
		s.compile("queued burst")
		assert.is_true(observed)
		assert.are.equal(total, errors.counts().error)
	end)

	it("terminates visibly and closes its spool if parsing fails", function()
		local spools, stopped = {}, false
		io.tmpfile = function()
			local file = assert(tmpfile())
			spools[#spools + 1] = file
			return file
		end
		parser.parse = function(buf, first, last)
			if first >= 4 then
				error("broken parser")
			end
			return parse(buf, first, last)
		end
		vim.fn.jobstop = function()
			stopped = true
			return 1
		end
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				local data = {}
				for i = 1, 3000 do
					data[i] = string.rep("x", 1024)
				end
				data[#data + 1] = ""
				opts.on_stdout(101, data)
			end)
			return 101
		end
		local ev = s.compile("parser failure")
		assert.are.equal(-1, ev.code)
		assert.is_true(stopped)
		assert.is_true(#spools > 0)
		for _, file in ipairs(spools) do
			assert.are.equal("closed file", io.type(file))
		end
		assert.is_false(runner.is_busy())
	end)

	it("reports spool creation failure instead of dropping output and succeeding", function()
		io.tmpfile = function()
			return nil, "no space"
		end
		vim.fn.jobstop = function()
			return 1
		end
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				opts.on_stdout(101, { string.rep("x", 2 * 1024 * 1024) })
				opts.on_exit(101, 0)
			end)
			return 101
		end
		local ev = s.compile("spool failure")
		assert.are.equal(-1, ev.code)
		assert.is_false(runner.is_busy())
	end)

	for _, operation in ipairs({ "write", "read" }) do
		it("fails and closes the spool on a " .. operation .. " error", function()
			local closed = false
			io.tmpfile = function()
				local file = assert(tmpfile())
				return {
					seek = function(_, ...)
						return file:seek(...)
					end,
					write = function(_, ...)
						if operation == "write" then
							return nil, "disk full"
						end
						return file:write(...)
					end,
					read = function()
						return nil
					end,
					close = function()
						closed = true
						return file:close()
					end,
				}
			end
			vim.fn.jobstop = function()
				return 1
			end
			vim.fn.jobstart = function(_, opts)
				vim.schedule(function()
					opts.on_stdout(101, { string.rep("x", 2 * 1024 * 1024) })
					opts.on_exit(101, 0)
				end)
				return 101
			end
			local ev = s.compile("disk error")
			assert.are.equal(-1, ev.code)
			assert.is_true(closed)
			assert.is_false(runner.is_busy())
		end)
	end

	for _, action in ipairs({ "interrupt", "delete" }) do
		it("closes an unread spool when the job is cancelled by " .. action, function()
			local files, cancelled = {}, false
			io.tmpfile = function()
				local file = assert(tmpfile())
				files[#files + 1] = file
				return file
			end
			vim.fn.jobstop = function()
				return 1
			end
			vim.fn.jobstart = function(_, opts)
				vim.schedule(function()
					opts.on_stdout(101, { string.rep("x", 2 * 1024 * 1024) })
					if action == "interrupt" then
						runner.stop()
					else
						vim.api.nvim_buf_delete(vim.g.compilation_buffer, { force = true })
					end
					cancelled = true
				end)
				return 101
			end
			require("compile-mode").compile({ args = "cancel spool", smods = { silent = true } })
			assert.is_true(vim.wait(1000, function()
				return cancelled
			end, 1))
			s.drain()
			assert.are.equal(1, #files)
			assert.are.equal("closed file", io.type(files[1]))
			assert.is_false(runner.is_busy())
			assert.is_nil(vim.g.compile_job_id)
		end)
	end

	it("updates metadata when an interruption footer trims limited output", function()
		local config = require("compile-mode.config.internal")
		config.max_lines = 3
		local buf = s.buffer({
			"h1",
			"h2",
			"h3",
			"h4",
			"f.c:1:1: error: first",
			"f.c:2:1: error: second",
			"f.c:3:1: error: third",
		})
		vim.g.compilation_buffer, vim.g.compile_job_id = buf, 101
		parser.parse(buf, 0, -1)
		vim.fn.jobstop = function()
			return 1
		end
		runner.stop()
		s.drain()
		assert.are.same({ 5 }, errors.ordered_lines())
		assert.are.equal(3, errors.error_list[5].row.value)
		assert.are.equal(5, errors.error_list[5].linenum)
	end)

	it("releases setup ownership when the compilation buffer is wiped before resume", function()
		local cm = require("compile-mode")
		cm.compile({ args = "never starts", smods = { silent = true } })
		local buf = vim.fn.bufnr(require("compile-mode.config.internal").buffer_name)
		vim.api.nvim_buf_delete(buf, { force = true })
		s.drain()
		assert.is_false(runner.is_busy())
		assert.is_nil(vim.g.compile_job_id)
	end)
end)
