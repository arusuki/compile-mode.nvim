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
end)
