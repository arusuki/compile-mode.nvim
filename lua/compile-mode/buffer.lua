local utils = require("compile-mode.utils")

local M = {}

local header_line_count = require("compile-mode.constants").header_line_count

---Follow live output in windows displaying the compilation buffer.
---@param bufnr integer
function M.scroll(bufnr)
	if not require("compile-mode.config.internal").auto_scroll then
		return
	end
	local last = vim.api.nvim_buf_line_count(bufnr)
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		vim.api.nvim_win_set_cursor(win, { last, 0 })
	end
end

---@param bufnr integer
---@param start integer
---@param end_ integer
---@param data string[]
---@param trim? boolean
---@return integer removed_lines
function M.set_lines(bufnr, start, end_, data, trim)
	local config = require("compile-mode.config.internal")

	if vim.fn.bufexists(bufnr) == 0 then
		return 0
	end

	utils.buf_set_opt(bufnr, "modifiable", true)
	vim.api.nvim_buf_set_lines(bufnr, start, end_, false, data)

	local removed_lines = 0
	if trim ~= false and config.max_lines then
		local effective_max_lines = config.max_lines + header_line_count

		local line_count = vim.api.nvim_buf_line_count(bufnr)
		removed_lines = math.max(line_count - effective_max_lines, 0)

		if removed_lines > 0 then
			vim.api.nvim_buf_set_lines(bufnr, header_line_count, header_line_count + removed_lines, false, {})
		end
	end

	vim.schedule(function()
		utils.buf_set_opt(bufnr, "modifiable", false)
		utils.buf_set_opt(bufnr, "modified", false)
	end)

	M.scroll(bufnr)

	return removed_lines
end

---Close the compilation buffer.
function M.close()
	local bufnr = vim.g.compilation_buffer

	local win_ids = vim.fn.win_findbuf(bufnr)

	if #vim.api.nvim_list_wins() > 1 then
		vim.iter(win_ids):each(function(win_id)
			vim.api.nvim_win_close(win_id, true)
		end)
	elseif vim.fn.bufexists("#") ~= 0 then
		vim.cmd.buffer("#")
	else
		vim.cmd.bnext()
	end
end

return M
