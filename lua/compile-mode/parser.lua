local a = require("plenary.async")
local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local cdir = require("compile-mode.dir")
local state = require("compile-mode.state")

local M = {}

---Scan a buffer range and update error/directory metadata.
---Buffer ranges are zero-based and end-exclusive; stored line numbers are one-based.
---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@return table[] output_highlights
function M.scan(bufnr, start_line, end_line)
	local config = require("compile-mode.config.internal")

	local output_highlights = {}

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
	for linenum, line in ipairs(lines) do
		linenum = start_line + linenum

		local error = errors.parse(line, linenum)

		if error then
			errors.error_list[linenum] = error

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
					cdir.dir_changes[linenum] = vim.fn.fnamemodify(dir, ":p:h" .. (leaving and ":h" or ""))
				else
					local latest_dir = cdir.find_directory_for_line(linenum)
					if leaving then
						cdir.dir_changes[linenum] = vim.fn.fnamemodify(latest_dir, ":h")
					else
						cdir.dir_changes[linenum] = vim.fn.resolve(latest_dir .. "/" .. dir)
					end
				end
			end

			if not (linenum == 1 and vim.startswith(line, "vim:")) then
				local highlights = utils.match_command_ouput(line, linenum)
				for _, value in ipairs(highlights) do
					table.insert(output_highlights, value)
				end
			end
		end
	end

	return output_highlights
end

---Apply highlights and refresh status after a scan.
---@param bufnr integer
---@param output_highlights table[]
function M.render(bufnr, output_highlights)
	errors.highlight(bufnr)
	utils.highlight_command_outputs(bufnr, output_highlights)
	vim.cmd.redrawstatus()
end

---@type fun(bufnr: integer, start_line: integer, end_line: integer)
M.parse = a.void(function(bufnr, start_line, end_line)
	local output_highlights = M.scan(bufnr, start_line, end_line)
	M.render(bufnr, output_highlights)
end)

return M
