local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local cdir = require("compile-mode.dir")
local state = require("compile-mode.state")
local input = require("compile-mode.input")

local M = {}
local namespace = vim.api.nvim_create_namespace("compile-mode.nvim")
local redraw_pending = false
local last_status
local last_counts = { error = 0, warning = 0, info = 0 }
local active_errors, active_buffer
local previous_line_count = 0
local scan_version = 0
local command_versions = {}
local logs = {}
local log_watchers = {}

---@class CompileModeScanHighlights: table
---@field _errors? table<integer, CompileModeError>
---@field _parsed? table<integer, CompileModeError>
---@field _version? integer
---@field _buffer? integer
---@field _rendered? boolean
---@field _log_version? integer

local function index(line, count)
	return math.max(0, math.min(count, line < 0 and count + line + 1 or line))
end

local function clear_metadata(first, last)
	errors.clear_range(first, last)
	cdir.clear_range(first, last)
	for line = first, last do
		command_versions[line] = nil
	end
end

---Scan a buffer range and update error/directory metadata.
---Buffer ranges are zero-based and end-exclusive; stored line numbers are one-based.
---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@return CompileModeScanHighlights output_highlights
function M.scan(bufnr, start_line, end_line)
	local config = require("compile-mode.config.internal")
	local line_count = input.count(bufnr)
	start_line = index(start_line, line_count)
	end_line = index(end_line, line_count)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

	if active_errors ~= errors.error_list or active_buffer ~= bufnr then
		active_errors = errors.error_list
		active_buffer = bufnr
		previous_line_count = 0
		command_versions = {}
	end
	-- A shortened log can leave metadata past its new last line. Appending to a
	-- log takes no full-table pass; only deleted and reparsed rows are invalidated.
	clear_metadata(line_count + 1, previous_line_count)
	previous_line_count = line_count
	if start_line == 0 and end_line == line_count then
		errors.clear_range(line_count + 1, math.huge)
		cdir.clear_range(line_count + 1, math.huge)
	end
	clear_metadata(start_line + 1, end_line)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, start_line, end_line)
	scan_version = scan_version + 1
	local output_highlights = {
		_errors = errors.error_list,
		_parsed = {},
		_version = scan_version,
		_buffer = bufnr,
		_log_version = logs[bufnr] and logs[bufnr].version,
	}

	for linenum, line in ipairs(lines) do
		linenum = start_line + linenum

		-- Keep oversized output intact, but bound synchronous matcher work.
		if
			not input.is_record(bufnr, linenum - 1)
			and (config.max_parse_line_length == 0 or #line <= config.max_parse_line_length)
		then
			local error = errors.parse(line, linenum)

			if error then
				errors.set_error(linenum, error)
				output_highlights._parsed[linenum] = error

				if config.auto_jump_to_first_error and not state.has_auto_jumped then
					state.has_auto_jumped = true
					local dir = cdir.find_directory_for_line(linenum)
					utils.jump_to_error(error, dir, {})
					state.error_cursor = linenum
				end
			else
				---@type CompileModeDirectoryMatcher
				local matcher = vim.iter(config.directory_change_matchers):find(function(matcher)
					local s0 = matcher._rx:match_str(line)
					return s0
				end)

				if matcher then
					local matches = vim.fn.matchlist(line, matcher.regex)

					local leaving = matcher.leaving and matches[matcher.leaving + 1] ~= ""
					local dir = matches[matcher.filename + 1]

					if utils.is_absolute(dir) then
						cdir.set_directory(linenum, vim.fn.fnamemodify(dir, ":p:h" .. (leaving and ":h" or "")))
					else
						local latest_dir = cdir.find_directory_for_line(linenum)
						if leaving then
							cdir.set_directory(linenum, vim.fn.fnamemodify(latest_dir, ":h"))
						else
							cdir.set_directory(linenum, vim.fn.resolve(latest_dir .. "/" .. dir))
						end
					end
				end

				if not (linenum == 1 and vim.startswith(line, "vim:")) then
					local highlights = utils.match_command_ouput(line, linenum)
					if #highlights > 0 then
						command_versions[linenum] = scan_version
					end
					for _, value in ipairs(highlights) do
						table.insert(output_highlights, value)
					end
				end
			end
		end
	end

	return output_highlights
end

---Apply highlights and refresh status after a scan.
---@param bufnr integer
---@param output_highlights CompileModeScanHighlights
function M.render(bufnr, output_highlights)
	if output_highlights._errors then
		if
			output_highlights._rendered
			or output_highlights._errors ~= errors.error_list
			or output_highlights._buffer ~= active_buffer
			or (
				output_highlights._log_version
				and (not logs[bufnr] or logs[bufnr].version ~= output_highlights._log_version)
			)
		then
			return
		end
		output_highlights._rendered = true
		errors.highlight(bufnr, output_highlights._parsed)
		for _, highlight in ipairs(output_highlights) do
			if command_versions[highlight[2]] == output_highlights._version then
				utils.add_highlight(bufnr, unpack(highlight))
			end
		end
	else
		-- Keep callers supplying a manually assembled highlight list working.
		errors.highlight(bufnr)
		utils.highlight_command_outputs(bufnr, output_highlights)
	end
	-- Inspect current metadata rather than a scan-local delta: deferred scans may
	-- be superseded or rendered out of order. Counts are maintained by setters.
	local counts = errors.counts()
	local job_id, exit_code = vim.g.compile_job_id, vim.g.compilation_exit_code
	local status = job_id and "run" or (exit_code and "exit:" .. exit_code or nil)
	local status_changed = counts.error ~= last_counts.error
		or counts.warning ~= last_counts.warning
		or counts.info ~= last_counts.info
		or status ~= last_status
	last_counts, last_status = counts, status
	if status_changed and not redraw_pending then
		redraw_pending = true
		vim.schedule(function()
			redraw_pending = false
			vim.cmd.redrawstatus()
		end)
	end
end

---@param bufnr integer
---@param start_line integer
---@param end_line integer
function M.parse(bufnr, start_line, end_line)
	local output_highlights = M.scan(bufnr, start_line, end_line)
	M.render(bufnr, output_highlights)
end

-- Running commands own the shared session, including their preparation yields.
-- Read the runner lazily to avoid the parser/runner module-loading cycle.
local function compilation_busy()
	local runner = package.loaded["compile-mode.runner"]
	return vim.g.compile_job_id ~= nil or (runner and runner.is_busy and runner.is_busy())
end

local function owns(bufnr)
	return active_buffer == bufnr and active_errors == errors.error_list
end

---Select a compilation buffer after the user enters it. Background log updates
---never take ownership from another log or an active command.
---@param bufnr integer
function M.activate(bufnr)
	if compilation_busy() or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	if not vim.b[bufnr].compilation_main_buffer and not logs[bufnr] and vim.bo[bufnr].filetype == "compilation" then
		M.attach_log(bufnr)
		return
	end
	vim.g.compilation_buffer = bufnr
	local log_state = logs[bufnr]
	if not owns(bufnr) then
		require("compile-mode.source_locations").reset()
		errors.error_list = {}
		cdir.dir_changes = {}
		state.error_cursor = 0
		if log_state then
			log_state.dirty = nil
		end
		M.parse(bufnr, 0, -1)
	elseif log_state and log_state.dirty then
		local first = log_state.dirty
		log_state.dirty = nil
		-- Rebuild the affected suffix: line insertions/deletions shift every
		-- later record, and directory messages can change all following paths.
		M.parse(bufnr, first, -1)
	end
end

---@param bufnr integer
function M.detach_log(bufnr)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	logs[bufnr] = nil
end

---Observe editable logs without repeatedly scanning their unchanged prefix.
---The attach callback only records changes; parsing is coalesced outside textlock.
---@param bufnr integer
function M.attach_log(bufnr)
	local log_state = logs[bufnr]
	if log_state then
		M.activate(bufnr)
		return
	end
	log_state = { dirty = 0, version = 0, scheduled = false }
	logs[bufnr] = log_state
	-- Keep the existing Lua attachment through immediate filetype re-entry.
	-- Lua cannot detach via nvim_buf_detach(); an inactive watcher removes
	-- itself on the next update instead of accumulating another attachment.
	if log_watchers[bufnr] then
		M.activate(bufnr)
		return
	end
	local watcher = {}
	log_watchers[bufnr] = watcher
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, buf, _, first, last, new_last)
			local current = logs[buf]
			if not current or vim.bo[buf].filetype ~= "compilation" or vim.b[buf].compilation_main_buffer then
				log_watchers[buf] = nil
				logs[buf] = nil
				return true
			end
			local log_state = current
			log_state.dirty = math.min(log_state.dirty or first, first)
			log_state.version = log_state.version + 1
			if owns(buf) and not compilation_busy() and new_last ~= last then
				if state.error_cursor > last then
					state.error_cursor = state.error_cursor + new_last - last
				elseif state.error_cursor > first then
					-- A deleted/replaced selection no longer denotes a source row.
					state.error_cursor = 0
				end
			end
			if not log_state.scheduled then
				log_state.scheduled = true
				vim.schedule(function()
					log_state.scheduled = false
					if logs[buf] == log_state and owns(buf) then
						M.activate(buf)
					end
				end)
			end
		end,
		on_reload = function(_, buf)
			local current = logs[buf]
			if not current then
				return
			end
			current.dirty = 0
			current.version = current.version + 1
			vim.schedule(function()
				if logs[buf] == current and owns(buf) then
					M.activate(buf)
				end
			end)
		end,
		on_detach = function(_, buf)
			if log_watchers[buf] == watcher then
				log_watchers[buf] = nil
				logs[buf] = nil
			end
		end,
	})
	M.activate(bufnr)
end

return M
