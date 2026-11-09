-- A protected transcript followed by an editable, independently undoable draft.
local M = {}
local states = {}
local sessions = {}
local ns = vim.api.nvim_create_namespace("compile-mode.input")
local group = vim.api.nvim_create_augroup("compile-mode.input", { clear = false })

local function mark(buf, s)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	if s.start then
		vim.api.nvim_buf_set_extmark(buf, ns, s.start, 0, {
			right_gravity = true,
			virt_text = { { s.active and "  [stdin · :w sends]" or "  [unsent input · process ended]", "Comment" } },
			virt_text_pos = "eol",
		})
	end
end

function M.has_draft(buf)
	local s = states[buf]
	return s and s.start ~= nil and table.concat(s.draft, "\n") ~= "" or false
end

function M.count(buf)
	local s = states[buf]
	return s and s.start or vim.api.nvim_buf_line_count(buf)
end

function M.is_record(buf, row)
	local s = states[buf]
	return s and s.records[row] or false
end

function M.output_count(buf)
	local s = states[buf]
	return M.count(buf) - (s and vim.tbl_count(s.records) or 0)
end

function M.in_draft(buf, win)
	local s = states[buf]
	return s and s.start and vim.api.nvim_win_get_cursor(win or 0)[1] > s.start or false
end

function M.lock(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local s = states[buf]
	vim.api.nvim_set_option_value("modifiable", s ~= nil and s.start ~= nil and not s.pending, { buf = buf })
	vim.api.nvim_set_option_value("modified", M.has_draft(buf), { buf = buf })
end

local function settle(buf, s)
	if not s.pending then
		return
	end
	local p = s.pending
	s.pending = nil
	s.editing = true
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, p.first, p.last, false, p.lines)
	s.editing = false
	mark(buf, s)
	M.lock(buf)
end

-- Output writers bracket synchronous text changes. Async highlight work must
-- never toggle modifiable independently of the input owner.
function M.begin_output(buf)
	local s = states[buf]
	if s then
		settle(buf, s)
		s.writing = true
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
end

function M.end_output(buf)
	local s = states[buf]
	if s then
		s.writing = false
		mark(buf, s)
	end
	M.lock(buf)
end

-- Most compilation jobs never read input. Keep their output path free of
-- buffer listeners, draft state, and changes to the native undo configuration.
local function activate(buf)
	if states[buf] then
		return states[buf]
	end
	local session = sessions[buf]
	if not session or not session.active then
		return nil
	end
	local s = { active = true, send = session.send, draft = { "" }, undo = { { "" } }, index = 1, records = {} }
	states[buf] = s
	s.old_undolevels = vim.bo[buf].undolevels
	-- Native undo includes process output. Keep a separate draft-only journal.
	vim.bo[buf].undolevels = -1
	vim.api.nvim_create_autocmd({ "InsertEnter", "InsertLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			s.insert_group = false
		end,
	})
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, b, _, first, last, new_last)
			if states[b] ~= s then
				return true
			end
			if s.editing then
				return
			end
			if s.writing then
				local shifted = {}
				for row in pairs(s.records) do
					if row < first then
						shifted[row] = true
					elseif row >= last then
						shifted[row + new_last - last] = true
					end
				end
				s.records = shifted
				if not s.start then
					return
				end
				local values = vim.api.nvim_buf_get_lines(b, first, new_last, false)
				for _ = first + 1, last do
					table.remove(s.history, first + 1)
				end
				for i = #values, 1, -1 do
					table.insert(s.history, first + 1, values[i])
				end
				s.start = s.start + new_last - last
			elseif not s.start then
				return
			elseif first < s.start then
				local original = {}
				for row = first, last - 1 do
					original[#original + 1] = row < s.start and s.history[row + 1] or s.draft[row - s.start + 1]
				end
				s.pending = { first = first, last = new_last, lines = original }
				vim.bo[b].modifiable = false
				vim.schedule(function()
					if states[b] == s and vim.api.nvim_buf_is_valid(b) then
						settle(b, s)
						vim.notify("Compilation history is read-only", vim.log.levels.WARN)
					end
				end)
			else
				s.draft = vim.api.nvim_buf_get_lines(b, s.start, -1, false)
				if #s.draft == 0 then
					s.draft = { "" }
					s.pending = { first = s.start, last = s.start, lines = { "" } }
					vim.bo[b].modifiable = false
					vim.schedule(function()
						if states[b] == s and vim.api.nvim_buf_is_valid(b) then
							settle(b, s)
						end
					end)
				end
				while #s.undo > s.index do
					table.remove(s.undo)
				end
				local inserting = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
				if inserting and s.insert_group then
					s.undo[s.index] = vim.deepcopy(s.draft)
				else
					s.undo[#s.undo + 1] = vim.deepcopy(s.draft)
					local limit = math.max(2, vim.go.undolevels + 1)
					if #s.undo > limit then
						table.remove(s.undo, 1)
					end
					s.index = #s.undo
				end
				s.insert_group = inserting
			end
		end,
		on_detach = function()
			if states[buf] == s then
				states[buf] = nil
			end
		end,
	})
	return s
end

function M.attach(buf, send)
	M.detach(buf)
	local session = { active = true, send = send }
	sessions[buf] = session
	-- :w must work even before the first Insert command.
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			if sessions[buf] == session then
				sessions[buf], states[buf] = nil, nil
			end
		end,
	})
end

function M.detach(buf)
	sessions[buf] = nil
	vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
	local s = states[buf]
	if s and vim.api.nvim_buf_is_valid(buf) then
		settle(buf, s)
		vim.bo[buf].undolevels = s.old_undolevels
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end
	states[buf] = nil
end

function M.enter(buf, key)
	local s = activate(buf)
	if not s or (not s.active and not s.start) then
		vim.notify("No running compilation", vim.log.levels.WARN)
		return
	end
	settle(buf, s)
	local in_draft = M.in_draft(buf)
	if not s.start then
		s.history = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		s.start = #s.history
		s.editing = true
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
		s.editing = false
	end
	if not in_draft then
		vim.api.nvim_win_set_cursor(0, { s.start + #s.draft, #s.draft[#s.draft] })
		key = "A"
	end
	mark(buf, s)
	M.lock(buf)
	-- feedkeys keeps normal Vim insertion semantics (including o/O and counts).
	local prefix = vim.v.count > 0 and tostring(vim.v.count) or ""
	vim.api.nvim_feedkeys(prefix .. (key or "i"), "ni", false)
end

function M.undo(buf, redo, count)
	local s = states[buf]
	if not s or not s.start then
		return
	end
	settle(buf, s)
	s.index = math.max(1, math.min(#s.undo, s.index + (redo and 1 or -1) * (count or 1)))
	s.draft = vim.deepcopy(s.undo[s.index])
	s.editing = true
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, s.start, -1, false, s.draft)
	s.editing = false
	mark(buf, s)
	M.lock(buf)
end

function M.submit(buf)
	local s = activate(buf)
	if not s or not s.active then
		error("No running compilation")
	end
	settle(buf, s)
	local text = table.concat(s.draft, "\n")
	if text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end
	local ok, err = s.send(text)
	if not ok then
		error(err)
	end
	if not s.start then
		-- :w without entering Insert still sends an empty answer.
		s.history = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		s.start = #s.history
	end
	local records = {}
	for _, line in ipairs(s.draft) do
		records[#records + 1] = "> " .. line
	end
	s.editing = true
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, s.start, -1, false, vim.list_extend(vim.deepcopy(records), { "" }))
	s.editing = false
	for i = 0, #records - 1 do
		s.records[s.start + i] = true
	end
	vim.list_extend(s.history, records)
	s.start = s.start + #records
	s.draft, s.undo, s.index = { "" }, { { "" } }, 1
	s.insert_group = false
	mark(buf, s)
	M.lock(buf)
end

function M.finish(buf)
	if sessions[buf] then
		sessions[buf].active = false
	end
	local s = states[buf]
	if not s then
		return
	end
	settle(buf, s)
	s.active = false
	if s.start and not M.has_draft(buf) then
		s.editing = true
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, s.start, -1, false, {})
		s.editing = false
		s.start = nil
		s.history = nil
	end
	mark(buf, s)
	M.lock(buf)
end

return M
