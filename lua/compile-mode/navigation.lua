local a = require("plenary.async")
local errors = require("compile-mode.errors")
local utils = require("compile-mode.utils")
local log = require("compile-mode.log")
local cdir = require("compile-mode.dir")
local state = require("compile-mode.state")

local M = {}

---Like `:find`, but splits unless `same_window` is configured.
---@param file string the file to find
---@param same_window boolean if `true`, do not split
local function file_find(file, same_window)
	if not same_window and vim.fn.filereadable(file) ~= 0 then
		vim.cmd("split")
	end

	local ok, msg = pcall(vim.cmd.find, file)
	if not ok then
		vim.notify(string.gsub(msg, "^Vim:", ""), vim.log.levels.ERROR)
	end
end

---Returns a function that acts like `gf` or `CTRL-W_f` (depending on the `same_window` parameter),
---while respecting "Entering directory" and "Leaving directory" messages.
---@param same_window boolean whether to split (i.e. act like `gf`) or not (i.e. act like `CTRL-W_f`)
---@return fun()
local function goto_file(same_window)
	return function()
		local cfile = vim.fn.expand("<cfile>")
		local linenum = unpack(vim.api.nvim_win_get_cursor(0))

		local dir = cdir.find_directory_for_line(linenum)

		vim.cmd("set path+=" .. dir)
		file_find(cfile, same_window)
		vim.cmd("set path-=" .. dir)
	end
end

---Create a command that takes some action on the next/previous error from the current error cursor.
---The command is repeated equal to the `count` that it receives, which defaults to `1`.
---
---@param action "jump"|"move" the action to do with the matching error:
--- * "jump" means go to the locus of the error
--- * "move" means scroll to the line in the compilation buffer
---@param direction "next"|"prev" what direction from the error cursor to find matches from:
--- * "next" means work forward from the current error
--- * "prev" means work backwards from the current error
---This also determines the printed message if there is no match in the specified direction.
---@param different_file boolean whether to only match errors that occur in different files from the current error
---@return fun(param: CommandParam?) command an async callback that performs the created action
local function act_from_current_error(action, direction, different_file)
	local name = (action == "jump" and "" or "move_to_") .. direction .. "_" .. (different_file and "file" or "error")
	return a.void(function(param)
		local config = require("compile-mode.config.internal")

		log.debug("calling " .. name .. "()")

		param = param or {}

		local count = param.count or 1
		local current_error = errors.error_list[state.error_cursor]

		local lines = vim.tbl_keys(errors.error_list)
		table.sort(lines)
		if direction == "prev" then
			lines = vim.fn.reverse(lines)
		end

		local function fits_constraints(line)
			local error = errors.error_list[line]
			if error.level < config.error_threshold then
				return false
			end
			if different_file and current_error and error.filename.value == current_error.filename.value then
				return false
			end
			return true
		end

		local error_line = nil
		local errors_found = 0
		local past_cursor = state.error_cursor == 0

		for _, line in ipairs(lines) do
			if line == state.error_cursor then
				past_cursor = true
			elseif past_cursor and fits_constraints(line) then
				errors_found = errors_found + 1
				if errors_found == count then
					error_line = line
					break
				end
			end
		end

		if not error_line and config.use_circular_error_navigation then
			local remaining_count = count - errors_found
			for _, line in ipairs(lines) do
				if fits_constraints(line) then
					remaining_count = remaining_count - 1
					if remaining_count == 0 then
						error_line = line
						break
					end
				end
			end
		end

		if not error_line then
			if not param.smods or not param.smods.silent then
				local message = direction == "next" and "past last" or "back before first"
				vim.notify("Moved " .. message .. " error")
			end
			return
		end

		state.error_cursor = error_line
		if action == "jump" then
			local dir = cdir.find_directory_for_line(error_line)
			utils.jump_to_error(errors.error_list[error_line], dir, param.smods or {})
		else
			vim.api.nvim_win_set_cursor(0, { error_line, 0 })
		end
	end)
end

---Jump to the Nth error in the error list, based on the count
---
---@type fun(param: CommandParam?)
M.first_error = a.void(
	---@param param CommandParam?
	function(param)
		local config = require("compile-mode.config.internal")

		log.debug("calling first_error()")

		param = param or {}

		local count = param.count or 1
		log.fmt_debug("count = %d", count)

		local lines = vim.iter(pairs(errors.error_list))
			:filter(function(_, error)
				return error.level >= config.error_threshold
			end)
			:map(function(line, _)
				return line
			end)
			:totable()

		if count < 1 then
			vim.notify("Moved back before first error")
			return
		end

		if count > #lines then
			vim.notify("Moved past last error")
			return
		end

		table.sort(lines)

		state.error_cursor = assert(lines[count])
		local error = assert(errors.error_list[state.error_cursor])

		local dir = cdir.find_directory_for_line(state.error_cursor)
		utils.jump_to_error(error, dir, param.smods or {})
	end
)

---Jump to the current error in the error list
---
---@type fun(param: CommandParam?)
M.current_error = a.void(
	---@param param CommandParam?
	function(param)
		log.debug("calling current_error()")

		param = param or {}

		log.fmt_debug("line = %d", state.error_cursor)

		local error = errors.error_list[state.error_cursor]
		if not error then
			if not param.smods or not param.smods.silent then
				vim.notify("No error currently loaded")
			end

			return
		end

		local dir = cdir.find_directory_for_line(state.error_cursor)
		utils.jump_to_error(error, dir, param.smods or {})
	end
)

---Jump to the next error in the error list.
M.next_error = act_from_current_error("jump", "next", false)

---Jump to the previous error in the error list.
M.prev_error = act_from_current_error("jump", "prev", false)

---Toggle "Next Error Follow", which causes the error under the cursor to be previewed whenever you move in the compilation buffer.
function M.next_error_follow()
	state.in_next_error_mode = not state.in_next_error_mode
	M.follow_cursor()
end

---Go to the error on the current line.
---
---@type fun(param: CommandParam?)
M.goto_error = a.void(
	---@param param CommandParam?
	function(param)
		log.debug("calling goto_error()")

		param = param or {}

		local linenum = unpack(vim.api.nvim_win_get_cursor(0))
		local error = errors.error_list[linenum]
		log.fmt_debug("error = %s", error)

		if not error then
			if not param.smods or not param.smods.silent then
				vim.notify("No error here")
			end

			return
		end

		local dir = cdir.find_directory_for_line(linenum)

		state.error_cursor = linenum
		utils.jump_to_error(error, dir, param.smods or {})
	end
)

---Print information about the error on the current line.
---
---@type fun()
M.debug_error = a.void(function()
	log.debug("calling debug_error()")

	local linenum = unpack(vim.api.nvim_win_get_cursor(0))
	local error = errors.error_list[linenum]
	if not error then
		vim.notify("No error here")
		return
	end

	print(("error = %s"):format(vim.inspect(error)))
end)

---Move to the location of the next error within the compilation buffer.
---Does not jump to the error's actual locus.
M.move_to_next_error = act_from_current_error("move", "next", false)

---Move to the location of the next error within the compilation buffer that has a different file to the current one.
---Does not jump to the error's actual locus.
M.move_to_next_file = act_from_current_error("move", "next", true)

---Move to the location of the previous error within the compilation buffer.
---Does not jump to the error's actual locus.
M.move_to_prev_error = act_from_current_error("move", "prev", false)

---Move to the location of the previous error within the compilation buffer that has a different file to the current one.
---Does not jump to the error's actual locus.
M.move_to_prev_file = act_from_current_error("move", "prev", true)

M.goto_file = goto_file(false)

M.split_goto_file = goto_file(true)

function M.follow_cursor()
	local compilation_buffer = vim.g.compilation_buffer

	if not state.in_next_error_mode then
		return
	end

	if vim.api.nvim_get_current_buf() ~= compilation_buffer then
		return
	end

	local cursor_row = unpack(vim.api.nvim_win_get_cursor(0))
	local error = errors.error_list[cursor_row]
	if not error then
		return
	end

	local preview_win
	local win_ids = vim.api.nvim_list_wins()
	if #win_ids == 1 then
		-- If there are no other windows, split a new one for the preview
		preview_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(true, true), false, { split = "below" })
	else
		-- If there is already a window for this file, use it
		preview_win = vim.iter(win_ids):find(function(win_id)
			local fbuf = vim.fn.bufadd(error.filename.value)
			local winbuf = vim.api.nvim_win_get_buf(win_id)
			return fbuf == winbuf
		end)
	end
	-- If we still don't have a preview window,
	-- use the first existing window that isn't the first compilation window
	if not preview_win then
		local past_first_window = false
		preview_win = vim.iter(win_ids):find(function(win_id)
			if past_first_window then
				return true
			end

			local winbuf = vim.api.nvim_win_get_buf(win_id)
			if winbuf ~= compilation_buffer then
				return true
			end

			past_first_window = true
			return false
		end)
	end

	vim.schedule(function()
		local dir = cdir.find_directory_for_line(cursor_row)
		vim.api.nvim_win_call(preview_win, function()
			utils.jump_to_error(error, dir, {})
		end)
		vim.notify("Current locus from " .. vim.fn.bufname(compilation_buffer))
	end)
end

return M
