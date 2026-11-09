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
		start()
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
