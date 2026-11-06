---@diagnostic disable: duplicate-set-field -- Test doubles are restored per case.
local assert = require("luassert")
local a = require("plenary.async")
local helpers = require("spec.test_helpers")
local s = require("scripts.support")
local utils = require("compile-mode.utils")
local runner = require("compile-mode.runner")
local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
local foreign = vim.api.nvim_create_namespace("cleanup-test-foreign")
local cm = require("compile-mode")

local function marks(buf, namespace)
	return vim.api.nvim_buf_get_extmarks(buf, namespace or ns, 0, -1, {})
end
local function timed_action(action)
	local delay = utils.delay
	local fired = false
	utils.delay = function(ms)
		if not fired then
			fired = true
			vim.defer_fn(action, 0)
		end
		return delay(ms)
	end
end

describe("bounded compilation highlight cleanup", function()
	local delay, jobstart, jobstop, launched, finished, event
	before_each(function()
		helpers.setup_tests()
		s.setup()
		delay, jobstart, jobstop = utils.delay, vim.fn.jobstart, vim.fn.jobstop
		launched, finished = {}, {}
		vim.fn.jobstart = function(command, opts)
			launched[#launched + 1] = command
			vim.schedule(function()
				local data = {}
				for i = 1, command == "seed" and 1024 or 1 do
					data[i] = "file.c:" .. i .. ":1: error: failure"
				end
				data[#data + 1] = ""
				opts.on_stdout(101, data)
				opts.on_exit(101, 0)
			end)
			return 101
		end
		vim.fn.jobstop = function()
			return 1
		end
		event = vim.api.nvim_create_autocmd("User", {
			pattern = "CompilationFinished",
			callback = function(ev)
				finished[#finished + 1] = ev.data.command
			end,
		})
	end)
	after_each(function()
		utils.delay, vim.fn.jobstart, vim.fn.jobstop = delay, jobstart, jobstop
		vim.api.nvim_del_autocmd(event)
	end)

	it("services timers before all old marks are cleared or the new process starts", function()
		local buf = s.compile("seed").bufnr
		assert.are.equal(4096, #marks(buf))
		local other = vim.api.nvim_buf_set_extmark(buf, foreign, 0, 0, {})
		local observed = false
		timed_action(function()
			local remaining = #marks(buf)
			observed = remaining > 0 and remaining < 4096 and #launched == 1
		end)
		s.compile("replacement")
		assert.is_true(observed)
		assert.are.equal(4, #marks(buf))
		assert.is_true(#vim.api.nvim_buf_get_extmark_by_id(buf, foreign, other, {}) > 0)
		assert.are.same({ "seed", "replacement" }, finished)
	end)

	it("abandons obsolete cleanup when a replacement is requested between chunks", function()
		local buf = s.compile("seed").bufnr
		timed_action(function()
			cm.compile({ args = "replacement", smods = { silent = true } })
		end)
		cm.compile({ args = "obsolete", smods = { silent = true } })
		assert.is_true(vim.wait(2000, function()
			return #finished == 2
		end, 1))
		s.drain()
		assert.are.same({ "seed", "replacement" }, launched)
		assert.are.same({ "seed", "replacement" }, finished)
		assert.are.equal(4, #marks(buf))
		assert.is_false(runner.is_busy())
	end)

	it("does not clear new marks after interruption during cleanup", function()
		local buf = s.compile("seed").bufnr
		local marker, interrupted
		timed_action(function()
			runner.interrupt()
			marker = vim.api.nvim_buf_set_extmark(buf, ns, 300, 0, {})
			interrupted = true
		end)
		cm.compile({ args = "obsolete", smods = { silent = true } })
		assert.is_true(vim.wait(2000, function()
			return interrupted and not runner.is_busy()
		end, 1))
		-- Wait through the old cleanup timer, not just two scheduled callbacks.
		local drained = false
		vim.defer_fn(function()
			drained = true
		end, 5)
		assert.is_true(vim.wait(2000, function()
			return drained
		end, 1))
		assert.is_true(#vim.api.nvim_buf_get_extmark_by_id(buf, ns, marker, {}) > 0)
		assert.are.same({ "seed" }, launched)
		assert.are.same({ "seed" }, finished)
	end)

	for _, unload in ipairs({ false, true }) do
		it(
			"releases ownership when the buffer is " .. (unload and "unloaded" or "deleted") .. " between chunks",
			function()
				local buf = s.compile("seed").bufnr
				local removed = false
				timed_action(function()
					vim.api.nvim_buf_delete(buf, { force = true, unload = unload })
					removed = true
				end)
				cm.compile({ args = "obsolete", smods = { silent = true } })
				assert.is_true(vim.wait(2000, function()
					return removed and not runner.is_busy()
				end, 1))
				assert.are.same({ "seed" }, launched)
				assert.are.same({ "seed" }, finished)
			end
		)
	end

	it("restarts its range after an edit shifts uncleared marks into cleared lines", function()
		local lines = {}
		for i = 1, 1024 do
			lines[i] = "line"
		end
		local buf = s.buffer(lines)
		vim.api.nvim_buf_set_extmark(buf, ns, 700, 0, {})
		local other = vim.api.nvim_buf_set_extmark(buf, foreign, 800, 0, {})
		timed_action(function()
			vim.api.nvim_buf_set_lines(buf, 0, 600, false, {})
		end)
		local done
		a.void(function()
			done = utils.clear_highlights(buf, function()
				return true
			end)
		end)()
		assert.is_true(vim.wait(2000, function()
			return done ~= nil
		end, 1))
		assert.is_true(done)
		assert.are.equal(0, #marks(buf))
		assert.are.same({ 200, 0 }, vim.api.nvim_buf_get_extmark_by_id(buf, foreign, other, {}))
		assert.are.equal(424, vim.api.nvim_buf_line_count(buf))
	end)

	it("keeps the synchronous API and clears EOF anchors without touching foreign marks", function()
		local buf = s.buffer({ "line" })
		vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { strict = false })
		vim.api.nvim_buf_set_extmark(buf, foreign, 0, 0, {})
		assert.is_true(utils.clear_highlights(buf))
		assert.are.equal(0, #marks(buf))
		assert.are.equal(1, #marks(buf, foreign))
	end)

	it("does no work when ownership is already lost", function()
		local buf = s.buffer({ "line" })
		vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {})
		assert.is_false(utils.clear_highlights(buf, function()
			return false
		end))
		assert.are.equal(1, #marks(buf))
	end)
end)
