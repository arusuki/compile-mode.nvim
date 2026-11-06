-- One compilation session is shared by commands, parsing, and navigation.
-- Keep error and directory tables in their existing modules for compatibility.
local errors = require("compile-mode.errors")
local cdir = require("compile-mode.dir")
local header_line_count = require("compile-mode.constants").header_line_count

local M = {
	error_cursor = 0,
	has_auto_jumped = false,
	in_next_error_mode = false,
}

function M.reset()
	M.error_cursor = 0
	M.has_auto_jumped = false
	errors.error_list = {}
	cdir.dir_changes = {}
	-- Cursor-follow mode is a user toggle and survives recompilation.
end

---@param line integer
---@param removed_lines integer
---@return integer|nil
local function shift_linenum(line, removed_lines)
	if line <= header_line_count then
		return line
	end

	if line <= header_line_count + removed_lines then
		return nil
	end

	return line - removed_lines
end

---@param removed_lines integer
function M.trim_lines(removed_lines)
	if removed_lines <= 0 then
		return
	end

	local new_error_list = {}
	for line, error in pairs(errors.error_list) do
		local new_line = shift_linenum(line, removed_lines)
		if new_line then
			error.linenum = new_line
			new_error_list[new_line] = error
		end
	end
	errors.error_list = new_error_list

	local new_dir_changes = {}
	for line, dir in pairs(cdir.dir_changes) do
		local new_line = shift_linenum(line, removed_lines)
		if new_line then
			new_dir_changes[new_line] = dir
		end
	end
	cdir.dir_changes = new_dir_changes

	M.error_cursor = shift_linenum(M.error_cursor, removed_lines) or 0
end

return M
