local assert = require("luassert")
local helpers = require("spec.test_helpers")
local s = require("scripts.support")

describe("queued output across scheduled callbacks", function()
	before_each(function()
		helpers.setup_tests()
		s.setup()
	end)

	it("reassembles an ANSI sequence once when replaying the raw unfinished line", function()
		local original = vim.fn.jobstart
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.jobstart = function(_, opts)
			vim.schedule(function()
				opts.on_stdout(987654, { "hello\27[" })
				-- Let the first callback be fully written and parsed before the
				-- continuation arrives, instead of merging both in one batch.
				vim.defer_fn(function()
					opts.on_stdout(987654, { "31mred\27[0m", "" })
					opts.on_exit(987654, 0)
				end, 20)
			end)
			return 987654
		end
		local ok, ev = xpcall(function()
			return s.compile("fragmented output")
		end, debug.traceback)
		vim.fn.jobstart = original
		assert.is_true(ok, ev)
		assert.are.same({ "hellored", "" }, vim.api.nvim_buf_get_lines(ev.bufnr, 4, -3, false))
	end)

	it("preserves ANSI line boundaries and fragmented streams above an unsent draft", function()
		local original = vim.fn.jobstart
		---@type table<string, function>
		local callbacks = {}
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.jobstart = function(_, opts)
			callbacks = opts
			return 987654
		end
		local ok, err = xpcall(function()
			s.compile("output while editing", function()
				assert.is_true(vim.wait(2000, function()
					return vim.g.compile_job_id == 987654
				end, 1))
				local buf = vim.g.compilation_buffer
				local function receive(stream, data, expected)
					callbacks["on_" .. stream](987654, data)
					assert.is_true(
						vim.wait(2000, function()
							return vim.deep_equal(expected, vim.api.nvim_buf_get_lines(buf, 4, -1, false))
						end, 1),
						vim.inspect(vim.api.nvim_buf_get_lines(buf, 4, -1, false))
					)
				end
				receive("stdout", { "prompt>", "" }, { "prompt>", "" })
				vim.api.nvim_set_current_buf(buf)
				local input = require("compile-mode.input")
				input.enter(buf)
				vim.api.nvim_feedkeys("", "nx", false)
				vim.api.nvim_buf_set_lines(buf, input.count(buf), -1, false, { "keep" })
				receive("stdout", { "\27[", "" }, { "prompt>", "\27[", "keep" })
				receive("stdout", { "31mplain", "" }, { "prompt>", "\27[", "31mplain", "keep" })
				receive("stdout", { "partial" }, { "prompt>", "\27[", "31mplain", "partial", "keep" })
				receive("stderr", { "warning", "" }, { "prompt>", "\27[", "31mplain", "partial", "warning", "keep" })
				receive(
					"stdout",
					{ " end", "", "" },
					{ "prompt>", "\27[", "31mplain", "partial end", "warning", "", "keep" }
				)
				callbacks.on_exit(987654, 0)
			end)
		end, debug.traceback)
		vim.fn.jobstart = original
		assert.is_true(ok, err)
	end)
end)
