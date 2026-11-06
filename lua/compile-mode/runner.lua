local a = require("plenary.async")
local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local log = require("compile-mode.log")
local cdir = require("compile-mode.dir")
local ansi = require("compile-mode.ansi")
local buffer = require("compile-mode.buffer")
local output = require("compile-mode.output")
local parser = require("compile-mode.parser")
local state = require("compile-mode.state")

local M = {}

local constants = require("compile-mode.constants")
local header_line_count = constants.header_line_count
local exit_code = constants.exit_code

---Await a subprocess; the first result counts callback entries, not complete lines.
---@type fun(cmd: string, bufnr: integer, param: CommandParam): integer, integer, integer, boolean
M.run_job = a.wrap(
	---@param cmd string
	---@param bufnr integer
	---@param param CommandParam
	---@param callback fun(integer, integer, integer, boolean)
	function(cmd, bufnr, param, callback)
		local config = require("compile-mode.config.internal")

		log.debug("calling runjob()")

		local count = 0
		local partial_line = ""
		local is_exited = false
		local line_limit_exceeded = false
		local job_id

		local on_either = a.void(function(_, data)
			if is_exited or not data or #data < 1 or (#data == 1 and data[1] == "") then
				return
			end

			local line_count = vim.api.nvim_buf_line_count(bufnr)

			count = count + #data

			local new_lines
			new_lines, partial_line = output.normalize(data, partial_line, config.hidden_output)

			local exceeded
			new_lines, exceeded = output.limit(new_lines, line_count, config.max_lines)
			if exceeded then
				line_limit_exceeded = true
				if #new_lines == 0 then
					vim.fn.jobstop(job_id)
					return
				end
				partial_line = new_lines[#new_lines]
			end

			-- Replace the unfinished last line, then interpret the rendered buffer.
			ansi.buf_set_lines(bufnr, -2, -1, new_lines)
			utils.wait()
			parser.parse(bufnr, line_count - 1, line_count - 1 + #new_lines)

			if line_limit_exceeded then
				vim.fn.jobstop(job_id)
			end
		end)

		log.debug("starting job...")
		job_id = vim.fn.jobstart(cmd, {
			cwd = cdir.compilation_directory,
			on_stdout = on_either,
			on_stderr = on_either,
			on_exit = function(id, code)
				is_exited = true
				local effective_code = line_limit_exceeded and exit_code.SIGTERM or code
				callback(count, effective_code, id, line_limit_exceeded)
			end,
			pty = config.use_pseudo_terminal,
			env = config.environment,
			clear_env = config.clear_environment,
		})
		log.fmt_debug("job_id = %d", job_id)

		if job_id <= 0 then
			vim.notify("Failed to start job with command " .. cmd, vim.log.levels.ERROR)
			return
		end

		vim.g.compile_job_id = job_id
		vim.cmd.redrawstatus()

		if param.bang then
			log.debug("sync mode - waiting for job to finish...")
			vim.fn.jobwait({ job_id })
		end

		vim.api.nvim_create_autocmd({ "BufDelete" }, {
			buffer = bufnr,
			callback = function()
				vim.g.compilation_exit_code = nil
				vim.g.compile_job_id = nil
				vim.fn.jobstop(job_id)
			end,
		})
	end,
	4
)

---Get the current time, formatted.
local function time()
	local config = require("compile-mode.config.internal")
	return vim.fn.strftime(config.time_format)
end

---Get the default directory, formatted.
local function default_dir()
	local cwd = cdir.compilation_directory or vim.fn.getcwd() --[[@as string]]
	return cwd:gsub("^" .. vim.env.HOME, "~")
end

---Run `command` and place the results in the "Compilation" buffer.
---
---@type fun(command: string, param: CommandParam)
M.run = a.void(
	---@param command string
	---@param param CommandParam
	function(command, param)
		local config = require("compile-mode.config.internal")

		log.debug("calling runcommand()")

		if config.ask_about_save and utils.ask_to_save(param.smods or {}) then
			return
		end

		state.reset()
		utils.clear_diagnostics()

		if vim.g.compile_job_id then
			if config.ask_to_interrupt then
				local response = vim.fn.confirm("Interrupt running process?", "&Yes\n&No")
				if response ~= 1 then
					return
				end
			end

			M.interrupt()

			utils.delay(1000)
		end

		if config.bang_expansion then
			command = vim.fn.expandcmd(command)
		end

		local error = errors.parse(command, header_line_count)
		if error then
			errors.error_list[header_line_count] = error
		end

		log.debug("opening compilation buffer...")

		local prev_win = vim.api.nvim_get_current_win()
		local bufnr = utils.split_unless_open(
			{ fname = config.buffer_name },
			vim.tbl_extend("force", param.smods or {}, { noswapfile = true }),
			param.count
		)
		utils.wait()

		utils.clear_highlights(bufnr)

		if config.focus_compilation_buffer then
			vim.api.nvim_set_current_win(vim.fn.win_findbuf(bufnr)[1])
		else
			vim.api.nvim_set_current_win(prev_win)
		end

		log.fmt_debug("bufnr = %d", bufnr)

		utils.buf_set_opt(bufnr, "buftype", "nofile")
		utils.buf_set_opt(bufnr, "buflisted", not config.hidden_buffer)

		-- reset compilation buffer
		buffer.set_lines(bufnr, 0, -1, {})
		utils.wait()

		vim.b[bufnr].compilation_main_buffer = true
		utils.buf_set_opt(bufnr, "filetype", "compilation")

		buffer.set_lines(bufnr, 0, 0, {
			"vim: filetype=compilation:path+=" .. default_dir(),
			"Compilation started at " .. time(),
			"",
			command,
		})

		utils.wait()
		parser.parse(bufnr, 0, -1)
		errors.highlight(bufnr)

		log.fmt_debug("running command: %s", command)

		local start_time = vim.loop.hrtime()

		local line_count, code, job_id, line_limit_exceeded = M.run_job(command, bufnr, param)

		local elapsed = (vim.loop.hrtime() - start_time) / 1e9

		if job_id ~= vim.g.compile_job_id then
			return
		end
		vim.g.compile_job_id = nil

		ansi.flush(bufnr)

		if line_count == 0 then
			state.trim_lines(buffer.set_lines(bufnr, -1, -1, { "" }))
		end

		local compilation_message
		if line_limit_exceeded then
			compilation_message = "Compilation terminated: max_lines reached"
		elseif code == exit_code.SUCCESS then
			compilation_message = "Compilation finished"
		elseif code == exit_code.SIGSEGV then
			compilation_message = "Compilation segmentation fault (core dumped)"
		elseif code == exit_code.SIGTERM then
			compilation_message = "Compilation terminated"
		else
			compilation_message = "Compilation exited abnormally with code " .. tostring(code)
		end
		vim.g.compilation_exit_code = code
		vim.cmd.redrawstatus()

		local fmt_elapsed = string.format(", duration %.2f s", elapsed)

		buffer.set_lines(bufnr, -1, -1, {
			compilation_message .. " at " .. time() .. fmt_elapsed,
			"",
		}, false)

		if not param.smods or not param.smods.silent then
			vim.notify(compilation_message)
		end

		vim.api.nvim_exec_autocmds("User", {
			pattern = "CompilationFinished",
			data = {
				command = command,
				code = code,
				bufnr = bufnr,
			},
		})

		utils.wait()
	end
)

---Interrupt the currently running compilation command.
---
---@type fun()
M.interrupt = a.void(function()
	log.debug("calling interrupt()")

	if not vim.g.compile_job_id then
		log.debug("nothing to interrupt")
		return
	end

	log.debug("interrupting compilation")
	log.fmt_debug("vim.g.compile_job_id = %d", vim.g.compile_job_id)

	local bufnr = vim.g.compilation_buffer
	log.fmt_debug("bufnr = %d", bufnr)

	local interrupt_message = "Compilation interrupted"

	buffer.set_lines(bufnr, -1, -1, {
		"",
		interrupt_message .. " at " .. time(),
	})
	utils.wait()

	local job_id = vim.g.compile_job_id
	vim.fn.jobstop(job_id)
	vim.g.compile_job_id = nil
	vim.api.nvim_exec_autocmds("User", {
		pattern = "CompilationInterrupted",
		data = {
			job_id = job_id,
			bufnr = bufnr,
		},
	})
end)

return M
