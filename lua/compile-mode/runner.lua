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
local input = require("compile-mode.input")

local M = {}

local constants = require("compile-mode.constants")
local header_line_count = constants.header_line_count
local exit_code = constants.exit_code

-- Ownership starts before buffer setup yields, not only after jobstart().
local current_session

function M.is_busy()
	return current_session ~= nil
end

---Await a subprocess; the first result counts callback entries, not complete lines.
---@type fun(cmd: string, bufnr: integer, param: CommandParam): integer, integer, integer, boolean
M.run_job = a.wrap(function(cmd, bufnr, param, callback)
	local config = require("compile-mode.config.internal")
	local owner = assert(current_session)
	local queue = require("compile-mode.output_queue").new()
	local count, job_id, exit_status, delete_event = 0, nil, nil, nil
	local finished, pumping, started, line_limit_exceeded = false, false, false, false
	local lookahead
	local streams = {
		stdout = { output = output.new_stream(config.hidden_output), ansi = {} },
		stderr = { output = output.new_stream(config.hidden_output), ansi = {} },
	}
	owner.streams = streams
	owner.pty = config.use_pseudo_terminal
	local empty_tail = true
	owner.input_sent = function()
		empty_tail = false
	end

	local function active()
		return current_session == owner and vim.api.nvim_buf_is_valid(bufnr)
	end

	local function cleanup()
		queue.close()
		lookahead = nil
		if delete_event then
			pcall(vim.api.nvim_del_autocmd, delete_event)
			delete_event = nil
		end
		owner.cancel = nil
	end

	local function pending_flush()
		if exit_status ~= nil and not line_limit_exceeded and not owner.failure then
			for _, name in ipairs({ "stdout", "stderr" }) do
				if streams[name].output.has_pending() then
					return name
				end
			end
		end
	end

	local function complete()
		if
			finished
			or not started
			or exit_status == nil
			or pumping
			or lookahead
			or not queue.empty()
			or pending_flush()
		then
			return
		end
		finished = true
		cleanup()
		callback(count, line_limit_exceeded and exit_code.SIGTERM or exit_status, job_id, line_limit_exceeded)
	end

	local function fail(reason)
		if finished then
			return
		end
		owner.failure = tostring(reason)
		exit_status, pumping = -1, false
		cleanup()
		if job_id and job_id > 0 then
			pcall(vim.fn.jobstop, job_id)
		end
		complete()
	end

	owner.cancel = function()
		if finished then
			return
		end
		finished = true
		cleanup()
		callback(count, exit_code.SIGTERM, job_id, false)
	end

	local function guarded(fn)
		if finished then
			return
		end
		if not active() then
			if owner.cancel then
				owner.cancel()
			end
			return
		end
		local ok, reason = xpcall(fn, debug.traceback)
		if not ok then
			fail(reason)
		end
	end

	local function take_batch()
		local item = assert(lookahead or queue.pop())
		lookahead = nil
		local data, bytes = item.data, item.bytes
		local fragments = { data[#data] }
		while #data < 128 and bytes < 65536 and not queue.empty() do
			local next_item = assert(queue.pop())
			if
				next_item.stream ~= item.stream
				or #data + #next_item.data - 1 > 128
				or bytes + next_item.bytes > 65536
			then
				lookahead = next_item
				break
			end
			fragments[#fragments + 1] = next_item.data[1]
			for i = 2, #next_item.data do
				data[#data] = table.concat(fragments)
				data[#data + 1] = next_item.data[i]
				fragments = { next_item.data[i] }
			end
			bytes = bytes + next_item.bytes
		end
		data[#data] = table.concat(fragments)
		return item.stream, data
	end

	local pump
	local function later(fn)
		-- A timer forces an event-loop poll; recursively scheduled continuations
		-- can otherwise starve timers/input while a complete backlog drains.
		vim.defer_fn(function()
			guarded(fn)
		end, 0)
	end

	pump = function()
		local stream_name, data, lines, partial, replay
		if lookahead or not queue.empty() then
			stream_name, data = take_batch()
			lines, partial, replay = streams[stream_name].output.push(data)
		else
			stream_name = pending_flush()
			if not stream_name then
				pumping = false
				complete()
				return
			end
			lines, partial, replay = streams[stream_name].output.flush()
		end
		if #lines == 0 then
			later(pump)
			return
		end
		local stream = streams[stream_name]
		local ranges = {}
		local function write(start, finish, values, first, offset)
			if #values == 0 then
				return
			end
			stream.ansi.replay_prefix = first and replay.prefix or nil
			stream.ansi.replay_reset = first and replay.reset or nil
			stream.ansi.discarded_prefix = first and replay.discarded or nil
			if replay.discarded_prefixes then
				stream.ansi.discarded_prefixes = {}
				for i = 1, #values do
					stream.ansi.discarded_prefixes[i] = replay.discarded_prefixes[i + (offset or 1) - 1]
				end
			else
				stream.ansi.discarded_prefixes = nil
			end
			ansi.buf_set_lines(bufnr, start, finish, values, true, stream.ansi)
			ranges[#ranges + 1] = { start, start + #values }
		end

		local line_count = input.count(bufnr)
		local old_row = stream.row
		if old_row and old_row < line_count - 1 then
			-- The other stream has appended output since this unfinished line.
			-- Replace only this row; subsequent lines append in arrival order.
			write(old_row, old_row + 1, { lines[1] }, true)
			table.remove(lines, 1)
			if #lines > 0 then
				stream.row = nil
			end
		end
		if #lines > 0 then
			local append = stream.row or (empty_tail and line_count - 1 or line_count)
			local replacing = append < line_count
			local available = config.max_lines
				and config.max_lines + header_line_count - input.output_count(bufnr) + (replacing and 1 or 0)
			if available and #lines > available then
				lines = vim.list_slice(lines, 1, math.max(0, available))
				line_limit_exceeded = true
			end
			write(
				append,
				replacing and append + 1 or append,
				lines,
				not old_row or old_row == line_count - 1,
				old_row and old_row < line_count - 1 and 2 or 1
			)
			if #lines > 0 then
				empty_tail = partial == ""
				stream.row = not empty_tail and append + #lines - 1 or nil
			end
		end
		if line_limit_exceeded then
			queue.close()
			lookahead = nil
			pcall(vim.fn.jobstop, job_id)
		end

		-- Let ANSI's scheduled marks finish before parsing. Parsing itself uses
		-- small slices plus an elapsed budget, including unusually costly regexes.
		local range_index, row = 1, ranges[1] and ranges[1][1]
		local function parse_ranges()
			local started_at = vim.uv.hrtime()
			while range_index <= #ranges do
				local range = ranges[range_index]
				local finish = math.min(row + 16, range[2])
				parser.parse(bufnr, row, finish)
				if finished or not active() then
					return
				end
				row = finish
				if row == range[2] then
					range_index = range_index + 1
					row = ranges[range_index] and ranges[range_index][1]
				end
				if vim.uv.hrtime() - started_at >= 5000000 and range_index <= #ranges then
					later(parse_ranges)
					return
				end
			end
			buffer.scroll(bufnr)
			if line_limit_exceeded or (not lookahead and queue.empty() and not pending_flush()) then
				pumping = false
				complete()
			else
				later(pump)
			end
		end
		vim.schedule(function()
			guarded(parse_ranges)
		end)
	end

	local function receive(stream, data)
		if
			finished
			or line_limit_exceeded
			or not active()
			or not data
			or #data == 0
			or (#data == 1 and data[1] == "")
		then
			return
		end
		guarded(function()
			count = count + #data
			queue.push(stream, data)
			if not pumping then
				pumping = true
				later(pump)
			end
		end)
	end

	local ok, result = pcall(vim.fn.jobstart, cmd, {
		cwd = owner.directory,
		on_stdout = function(_, data)
			receive("stdout", data)
		end,
		on_stderr = function(_, data)
			receive("stderr", data)
		end,
		on_exit = function(_, code)
			owner.exited = true
			if not owner.failure then
				exit_status = code
			end
			if pending_flush() and not pumping then
				pumping = true
				later(pump)
			end
			complete()
		end,
		pty = config.use_pseudo_terminal,
		env = config.environment,
		clear_env = config.clear_environment,
	})
	started = true
	job_id = ok and result or -1
	owner.job_id = job_id
	if finished or not active() then
		if job_id > 0 then
			pcall(vim.fn.jobstop, job_id)
		end
		if owner.cancel then
			owner.cancel()
		end
		return
	end
	if not ok or job_id <= 0 then
		fail(ok and ("Failed to start job: " .. tostring(job_id)) or result)
		return
	end
	vim.g.compile_job_id = job_id
	input.attach(bufnr, function(data)
		if current_session ~= owner or owner.exited or owner.stdin_closed then
			return false, "Compilation input is closed"
		end
		local sent, result = pcall(vim.fn.chansend, job_id, data)
		if not sent or result == 0 then
			return false, "Unable to send compilation input: " .. tostring(result)
		end
		owner.input_sent()
		return true
	end)
	vim.cmd.redrawstatus()
	delete_event = vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		buffer = bufnr,
		once = true,
		callback = function()
			if current_session == owner then
				current_session = nil
				vim.g.compilation_exit_code = nil
				vim.g.compile_job_id = nil
			end
			if owner.cancel then
				owner.cancel()
			end
			pcall(vim.fn.jobstop, job_id)
		end,
	})
	complete()
	if param.bang and not finished then
		vim.fn.jobwait({ job_id })
	end
end, 4)

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
---@type fun(command: string, param: CommandParam, directory?: string)
M.run = a.void(
	---@param command string
	---@param param CommandParam
	function(command, param, directory)
		local session
		local ok, reason = xpcall(function()
			local config = require("compile-mode.config.internal")

			log.debug("calling runcommand()")

			local old_buf = vim.g.compilation_buffer
			if old_buf and input.has_draft(old_buf) then
				if vim.fn.confirm("Discard unsent compilation input?", "&Yes\n&No", 2) ~= 1 then
					return
				end
			end

			if config.ask_about_save and utils.ask_to_save(param.smods or {}) then
				return
			end

			if current_session or vim.g.compile_job_id then
				if config.ask_to_interrupt then
					local response = vim.fn.confirm("Interrupt running process?", "&Yes\n&No")
					if response ~= 1 then
						return
					end
				end

				M.stop()
			end

			cdir.compilation_directory = directory or cdir.compilation_directory or vim.fn.getcwd()
			vim.g.compile_command = command
			session = { directory = cdir.compilation_directory }
			current_session = session
			vim.g.compilation_exit_code = nil
			local function owned()
				if current_session == session and session.bufnr and not vim.api.nvim_buf_is_loaded(session.bufnr) then
					current_session = nil
				end
				return current_session == session
			end

			state.reset()
			utils.clear_diagnostics()

			if config.bang_expansion then
				command = vim.fn.expandcmd(command)
			end

			local error = errors.parse(command, header_line_count)
			if error then
				errors.set_error(header_line_count, error)
			end

			log.debug("opening compilation buffer...")

			local prev_win = vim.api.nvim_get_current_win()
			local bufnr = utils.split_unless_open(
				{ fname = config.buffer_name },
				vim.tbl_extend("force", param.smods or {}, { noswapfile = true }),
				param.count
			)
			session.bufnr = bufnr
			utils.wait()
			if not owned() then
				return
			end

			if not utils.clear_highlights(bufnr, owned) then
				return
			end
			ansi.reset(bufnr)

			if config.focus_compilation_buffer then
				local win = vim.fn.win_findbuf(bufnr)[1]
				if win then
					vim.api.nvim_set_current_win(win)
				end
			elseif vim.api.nvim_win_is_valid(prev_win) then
				vim.api.nvim_set_current_win(prev_win)
			end

			log.fmt_debug("bufnr = %d", bufnr)

			utils.buf_set_opt(bufnr, "buftype", "nofile")
			utils.buf_set_opt(bufnr, "buflisted", not config.hidden_buffer)

			input.detach(bufnr)

			-- reset compilation buffer
			buffer.set_lines(bufnr, 0, -1, {})
			utils.wait()
			if not owned() then
				return
			end

			vim.b[bufnr].compilation_main_buffer = true
			utils.buf_set_opt(bufnr, "filetype", "compilation")

			buffer.set_lines(bufnr, 0, 0, {
				"vim: filetype=compilation:path+=" .. default_dir(),
				"Compilation started at " .. time(),
				"",
				command,
			})

			utils.wait()
			if not owned() then
				return
			end
			parser.parse(bufnr, 0, -1)
			errors.highlight(bufnr)

			log.fmt_debug("running command: %s", command)

			local start_time = vim.loop.hrtime()

			local line_count, code, _, line_limit_exceeded = M.run_job(command, bufnr, param)

			local elapsed = (vim.loop.hrtime() - start_time) / 1e9

			if not owned() then
				return
			end
			vim.g.compile_job_id = nil
			input.finish(bufnr)

			for _, stream in pairs(session.streams or {}) do
				ansi.flush(bufnr, stream.ansi)
			end

			if line_count == 0 then
				state.trim_lines(buffer.set_lines(bufnr, -1, -1, { "" }))
			end

			local compilation_message
			if session.failure then
				compilation_message = "Compilation failed: " .. session.failure:match("^[^\n]*")
			elseif line_limit_exceeded then
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

			current_session = nil
			vim.api.nvim_exec_autocmds("User", {
				pattern = "CompilationFinished",
				data = {
					command = command,
					code = code,
					bufnr = bufnr,
				},
			})

			utils.wait()
		end, debug.traceback)
		if not ok and session and current_session == session then
			current_session = nil
			vim.g.compile_job_id = nil
			vim.g.compilation_exit_code = -1
			if session.cancel then
				session.cancel()
			end
			if session.job_id and session.job_id > 0 then
				pcall(vim.fn.jobstop, session.job_id)
			end
			if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
				input.finish(session.bufnr)
				pcall(
					buffer.set_lines,
					session.bufnr,
					-1,
					-1,
					{ "Compilation failed: " .. tostring(reason):match("^[^\n]*"), "" },
					false
				)
			end
			vim.notify(tostring(reason), vim.log.levels.ERROR)
			vim.api.nvim_exec_autocmds("User", {
				pattern = "CompilationFinished",
				data = { command = command, code = -1, bufnr = session.bufnr },
			})
		end
	end
)

---Force-stop the currently running compilation and release its session.
---
---@type fun()
M.stop = a.void(function()
	local session = current_session
	local job_id = session and session.job_id or vim.g.compile_job_id
	if not session and not job_id then
		return
	end
	local bufnr = session and session.bufnr or vim.g.compilation_buffer
	current_session = nil
	vim.g.compile_job_id = nil
	vim.g.compilation_exit_code = nil
	if session and session.cancel then
		session.cancel()
	end
	if job_id and job_id > 0 then
		pcall(vim.fn.jobstop, job_id)
	end
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		input.finish(bufnr)
		state.trim_lines(buffer.set_lines(bufnr, -1, -1, {
			"",
			"Compilation interrupted at " .. time(),
		}))
	end
	vim.cmd.redrawstatus()
	utils.wait()
	vim.api.nvim_exec_autocmds("User", {
		pattern = "CompilationInterrupted",
		data = { job_id = job_id, bufnr = bufnr },
	})
end)

---Send a signal without relinquishing ownership of the running job.
---@param signal string|integer
---@return boolean, string?
function M.signal(signal)
	local session = current_session
	if not session or not session.job_id or session.exited then
		return false, "No running compilation"
	end
	return require("compile-mode.signals").send(session.job_id, signal)
end

---@return boolean, string?
function M.interrupt()
	return M.signal("INT")
end

---@return boolean, string?
function M.send_eof()
	local session = current_session
	if not session or not session.job_id or session.exited or session.stdin_closed then
		return false, "Compilation input is closed"
	end
	if input.has_draft(session.bufnr) then
		return false, "Submit the draft with :w before sending EOF"
	end
	local pty = session.pty
	local ok, result
	if pty then
		ok, result = pcall(vim.fn.chansend, session.job_id, "\004")
		ok = ok and result > 0
	else
		ok, result = pcall(vim.fn.chanclose, session.job_id, "stdin")
		if ok then
			session.stdin_closed = true
		end
	end
	return ok, not ok and tostring(result) or nil
end

return M
