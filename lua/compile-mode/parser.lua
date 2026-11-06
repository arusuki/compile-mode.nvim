local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local cdir = require("compile-mode.dir")
local state = require("compile-mode.state")

local M = {}
local namespace = vim.api.nvim_create_namespace("compile-mode.nvim")
local redraw_pending = false
local last_status
local last_counts = { error = 0, warning = 0, info = 0 }
local active_errors, active_buffer
local previous_line_count = 0
local scan_version = 0
local command_versions = {}

---@class CompileModeScanHighlights: table
---@field _errors? table<integer, CompileModeError>
---@field _parsed? table<integer, CompileModeError>
---@field _version? integer
---@field _buffer? integer
---@field _rendered? boolean

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
	local line_count = vim.api.nvim_buf_line_count(bufnr)
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
	}

	for linenum, line in ipairs(lines) do
		linenum = start_line + linenum

		-- Keep oversized output intact, but bound synchronous matcher work.
		if config.max_parse_line_length == 0 or #line <= config.max_parse_line_length then
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

return M
