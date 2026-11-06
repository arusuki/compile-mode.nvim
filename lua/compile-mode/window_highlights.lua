-- matchadd() highlights belong to windows, not buffers. Keep their lifetime
-- tied to the compilation buffer displayed by each window.
local M = {}
local buffers, windows = {}, {}
local group = vim.api.nvim_create_augroup("compile-mode-window-highlights", { clear = true })

local function clear(win)
	local owned = windows[win]
	if not owned then
		return
	end
	windows[win] = nil
	if vim.api.nvim_win_is_valid(win) then
		for _, id in ipairs(owned.ids) do
			pcall(vim.fn.matchdelete, id, win)
		end
	end
end

local function refresh(win)
	if not vim.api.nvim_win_is_valid(win) then
		windows[win] = nil
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local patterns = buffers[buf]
	if not patterns or vim.bo[buf].filetype ~= "compilation" then
		clear(win)
		return
	end
	local owned = windows[win]
	if owned and owned.buf == buf and owned.patterns == patterns then
		return
	end
	clear(win)
	local ids = {}
	for _, pattern in ipairs(patterns) do
		ids[#ids + 1] = vim.fn.matchadd(pattern[1], pattern[2], 10, -1, { window = win })
	end
	windows[win] = { buf = buf, patterns = patterns, ids = ids }
end

---@param bufnr integer
---@param patterns string[][]
function M.attach(bufnr, patterns)
	buffers[bufnr] = patterns
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		refresh(win)
	end
end

---@param bufnr integer
function M.detach(bufnr)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	buffers[bufnr] = nil
	for win, owned in pairs(windows) do
		if owned.buf == bufnr then
			clear(win)
		end
	end
end

vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "BufEnter", "FileType" }, {
	group = group,
	callback = function()
		refresh(vim.api.nvim_get_current_win())
	end,
})
vim.api.nvim_create_autocmd("BufWinLeave", {
	group = group,
	callback = function(ev)
		local win = vim.api.nvim_get_current_win()
		if windows[win] and windows[win].buf == ev.buf then
			clear(win)
		end
	end,
})
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
	group = group,
	callback = function(ev)
		M.detach(ev.buf)
	end,
})
vim.api.nvim_create_autocmd("WinClosed", {
	group = group,
	callback = function(ev)
		windows[tonumber(ev.match)] = nil
	end,
})

return M
