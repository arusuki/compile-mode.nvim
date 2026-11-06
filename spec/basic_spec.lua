local helpers = require("spec.test_helpers")
local assert = require("luassert")

local echoed = "hello world"
local cmd = "echo " .. echoed

describe(":Compile", function()
	before_each(helpers.setup_tests)

	it("should run a command and create a buffer with the result", function()
		helpers.compile({ args = cmd })

		assert.are.same({ cmd, echoed }, helpers.get_output())
	end)

	it("should clear previous errors and status counts when starting another command", function()
		local compile_mode = require("compile-mode")
		helpers.compile_error(helpers.sun_ada_error({ filename = "README.md", row = 1, col = 1 }))
		assert.is_true(compile_mode.statusline_info().counts.error > 0)
		helpers.next_error()

		helpers.compile({ args = cmd })
		assert.are.same({}, require("compile-mode.errors").error_list)
		assert.are.same({ error = 0, warning = 0, info = 0 }, compile_mode.statusline_info().counts)
		assert.are.same({ type = "exit", code = 0 }, compile_mode.statusline_info().status)
		assert.are.equal("Compilation:exit [0] [0 0 0]", compile_mode.statusline(false))
	end)
end)

describe(":Recompile", function()
	before_each(helpers.setup_tests)

	it("should rerun the latest command", function()
		helpers.compile({ args = cmd })

		local expected = helpers.get_output()
		helpers.recompile()

		assert.are.same(expected, helpers.get_output())
	end)
end)
