-- Source anchors are created only when a diagnostic is visited. They follow
-- edits and undo without changing the original compiler coordinates/exports.
local M = {}
local namespace = vim.api.nvim_create_namespace("compile-mode.nvim/source-locations")
local locations = {}
local buffers = {}

function M.release(error)
	local entry = locations[error]
	if not entry then
		return
	end
	locations[error] = nil
	local owned = buffers[entry.buffer]
	if owned then
		owned[error] = nil
		if not next(owned) then
			buffers[entry.buffer] = nil
		end
	end
	if vim.api.nvim_buf_is_valid(entry.buffer) then
		vim.api.nvim_buf_del_extmark(entry.buffer, namespace, entry.start)
		vim.api.nvim_buf_del_extmark(entry.buffer, namespace, entry.finish)
	end
end

function M.reset()
	for buffer in pairs(buffers) do
		if vim.api.nvim_buf_is_valid(buffer) then
			vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
		end
	end
	locations, buffers = {}, {}
end

-- Legacy callers may replace the public error table or invalidate it after an
-- in-place edit. Keep anchors for surviving records, including trimmed logs.
function M.retain(error_list)
	if not next(locations) then
		return
	end
	local retained = {}
	for _, error in pairs(error_list) do
		retained[error] = true
	end
	for error in pairs(locations) do
		if not retained[error] then
			M.release(error)
		end
	end
end

vim.api.nvim_create_autocmd("BufUnload", {
	group = vim.api.nvim_create_augroup("compile-mode-source-locations", { clear = true }),
	callback = function(event)
		-- Reloaded files have new text; do not reuse anchors from the old text.
		if buffers[event.buf] then
			vim.api.nvim_buf_clear_namespace(event.buf, namespace, 0, -1)
		end
		for error in pairs(buffers[event.buf] or {}) do
			locations[error] = nil
		end
		buffers[event.buf] = nil
	end,
})

---@param buffer integer
---@param error CompileModeError
---@param start integer[]
---@param finish integer[]
---@return integer[], integer[]
function M.resolve(buffer, error, start, finish)
	if not error.row then
		M.release(error)
		return start, finish
	end
	local signature = {
		filename = error.filename.value,
		row = error.row.value,
		col = error.col and error.col.value,
		end_row = error.end_row and error.end_row.value,
		end_col = error.end_col and error.end_col.value,
	}
	local entry = locations[error]
	if entry and entry.buffer == buffer and vim.deep_equal(entry.signature, signature) then
		local first = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, entry.start, {})
		local last = vim.api.nvim_buf_get_extmark_by_id(buffer, namespace, entry.finish, {})
		if #first > 0 and #last > 0 then
			return first, last
		end
	end
	M.release(error)
	local function anchor(position)
		return vim.api.nvim_buf_set_extmark(buffer, namespace, position[1], position[2], {
			right_gravity = true,
			undo_restore = true,
		})
	end
	locations[error] = {
		buffer = buffer,
		signature = signature,
		start = anchor(start),
		finish = anchor(finish),
	}
	buffers[buffer] = buffers[buffer] or {}
	buffers[buffer][error] = true
	return start, finish
end

return M
