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
		local line_limit_exceeded = false
		local job_id, exit_status, delete_event
		local finished, pumping = false, false
		local pending, head, tail = {}, 1, 0

		local function active()
			return vim.g.compile_job_id == job_id and vim.api.nvim_buf_is_valid(bufnr)
		end

		local function complete()
			if finished or exit_status == nil or pumping or head <= tail then
				return
			end
			finished = true
			if delete_event then
				pcall(vim.api.nvim_del_autocmd, delete_event)
			end
			callback(count, line_limit_exceeded and exit_code.SIGTERM or exit_status, job_id, line_limit_exceeded)
		end

		-- Merge adjacent callback tails, while bounding each write/scan. Keep a
		-- head index instead of shifting the backlog on every dequeue.
		local function take_batch()
			local data, bytes = {}, 0
			local fragments
			local function join_tail()
				if fragments then
					data[#data] = table.concat(fragments)
					fragments = nil
				end
			end
			while head <= tail and #data < 128 and bytes < 65536 do
				local item = pending[head]
				while item.index <= #item.data and #data < 128 and bytes < 65536 do
					local value = item.data[item.index]
					if item.index == 1 and #data > 0 then
						fragments = fragments or { data[#data] }
						fragments[#fragments + 1] = value
					else
						join_tail()
						data[#data + 1] = value
					end
					bytes = bytes + #value
					item.index = item.index + 1
				end
				if item.index <= #item.data then
					-- The next entry follows a newline. Leave a replaceable empty
					-- tail, just like a callback ending at that newline would.
					join_tail()
					data[#data + 1] = ""
					break
				end
				pending[head] = nil
				head = head + 1
			end
			join_tail()
			return data
		end

		local pump = a.void(function()
			while head <= tail and active() and not line_limit_exceeded do
				local line_count = vim.api.nvim_buf_line_count(bufnr)
				local new_lines
				new_lines, partial_line = output.normalize(take_batch(), partial_line, config.hidden_output)
				new_lines, line_limit_exceeded = output.limit(new_lines, line_count, config.max_lines)
				if #new_lines > 0 then
					ansi.buf_set_lines(bufnr, -2, -1, new_lines, true)
					-- Baleia schedules highlights. Finish those before interpreting
					-- the written range or publishing CompilationFinished.
					utils.wait()
					if not active() then
						break
					end
					parser.parse(bufnr, line_count - 1, line_count - 1 + #new_lines)
					buffer.scroll(bufnr)
				end
				if line_limit_exceeded then
					vim.fn.jobstop(job_id)
				end
				-- A single scheduled callback must not drain an unbounded log.
				utils.wait()
			end
			if not active() or line_limit_exceeded then
				pending, head, tail = {}, 1, 0
			end
			pumping = false
			complete()
		end)

		local function on_either(_, data)
			if finished or line_limit_exceeded or not data or #data < 1 or (#data == 1 and data[1] == "") then
				return
			end
			count = count + #data
			tail = tail + 1
			pending[tail] = { data = data, index = 1 }
			if not pumping then
				pumping = true
				vim.schedule(pump)
			end
		end

		log.debug("starting job...")
		job_id = vim.fn.jobstart(cmd, {
			cwd = cdir.compilation_directory,
			on_stdout = on_either,
			on_stderr = on_either,
			on_exit = function(_, code)
				exit_status = code
				complete()
			end,
			pty = config.use_pseudo_terminal,
			env = config.environment,
			clear_env = config.clear_environment,
		})
		log.fmt_debug("job_id = %d", job_id)

		if job_id <= 0 then
			vim.notify("Failed to start job with command " .. cmd, vim.log.levels.ERROR)
			exit_status = job_id
			complete()
			return
		end

		vim.g.compile_job_id = job_id
		vim.cmd.redrawstatus()

		delete_event = vim.api.nvim_create_autocmd("BufDelete", {
			buffer = bufnr,
			once = true,
			callback = function()
				if vim.g.compile_job_id == job_id then
					vim.g.compilation_exit_code = nil
					vim.g.compile_job_id = nil
				end
				vim.fn.jobstop(job_id)
			end,
		})

		if param.bang then
			log.debug("sync mode - waiting for job to finish...")
			vim.fn.jobwait({ job_id })
		end
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

		state.reset()
		utils.clear_diagnostics()

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
		ansi.reset(bufnr)

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
	-- Revoke ownership before yielding so queued output cannot overwrite the
	-- interruption message or leak into a subsequent compilation.
	local job_id = vim.g.compile_job_id
	vim.g.compile_job_id = nil
	vim.fn.jobstop(job_id)

	local interrupt_message = "Compilation interrupted"

	buffer.set_lines(bufnr, -1, -1, {
		"",
		interrupt_message .. " at " .. time(),
	})
	utils.wait()

	vim.api.nvim_exec_autocmds("User", {
		pattern = "CompilationInterrupted",
		data = {
			job_id = job_id,
			bufnr = bufnr,
		},
	})
end)

return M
