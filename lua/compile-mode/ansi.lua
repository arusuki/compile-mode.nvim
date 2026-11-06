local log = require("compile-mode.log")

-- Lua pattern building blocks for ANSI escape sequence processing.
-- All patterns are sourced from Emacs' ansi-color.el and ansi-osc.el.
-- See:
-- - https://github.com/emacs-mirror/emacs/blob/master/lisp/ansi-color.el
-- - https://github.com/emacs-mirror/emacs/blob/master/lisp/ansi-osc.el

local ESC = "\x1b" -- ESC byte (0x1B)

-- CSI (Control Sequence Introducer) structure:
--   ESC [ <parameter bytes> <intermediate bytes> <final byte>
-- Parameter bytes: 0x30-0x3F (0-9 : ; < = > ?)
-- Intermediate bytes: 0x20-0x2F (space through /)
-- Final bytes: 0x40-0x7E (@ through ~)

local CSI_INTRO = ESC .. "%["
local CSI_PARAM = "[%d:;<=>?]*"
local CSI_INTERMEDIATE = "[ -/]*"
local CSI_FINAL = "[@-~]"
local CSI_FINAL_NON_SGR = "[@-ln-~]" -- excludes m (0x6D, SGR final byte)

-- Composed CSI patterns
local CSI_COMPLETE = CSI_INTRO .. CSI_PARAM .. CSI_INTERMEDIATE .. CSI_FINAL
local CSI_NON_SGR = CSI_INTRO .. CSI_PARAM .. CSI_INTERMEDIATE .. CSI_FINAL_NON_SGR
local CSI_SGR = CSI_INTRO .. CSI_PARAM .. CSI_INTERMEDIATE .. "m"

-- Partial CSI patterns (incomplete sequences at end of input)
local PARTIAL_CSI = CSI_INTRO .. CSI_PARAM .. CSI_INTERMEDIATE .. "$"
local LONE_ESC = ESC .. "$"

-- OSC (Operating System Command) structure:
--   ESC ] <command> ; <data> <terminator>
-- Terminators: BEL (0x07) or ESC \ (ST)

local OSC_INTRO = ESC .. "%]"
local OSC_CMD = "(%d+)" -- captures command number
local OSC_SEP = ";"
local OSC_DATA = "([^\x07\x1b]-)" -- captures data (non-greedy, stops at BEL or ESC)
local BEL = "\x07" -- BEL byte (0x07)
local ST = ESC .. "\\" -- String Terminator: ESC \
local OSC_TEXT = "[^\x07\x1b]*" -- for BEL-terminated and partial patterns
local OSC_TEXT_ST = "[^\x1b]*" -- for ST-terminated (BEL is allowed in data)

-- Composed OSC patterns with captures (for handler dispatch)
local OSC_BEL_PATTERN = OSC_INTRO .. OSC_CMD .. OSC_SEP .. OSC_DATA .. BEL
local OSC_ST_PATTERN = OSC_INTRO .. OSC_CMD .. OSC_SEP .. OSC_DATA .. ST

-- Composed OSC patterns without captures (for stripping)
local OSC_BEL_TERM = OSC_INTRO .. OSC_TEXT .. BEL
local OSC_ST_TERM = OSC_INTRO .. OSC_TEXT_ST .. ST

-- Partial OSC pattern (incomplete sequence at end of input)
local PARTIAL_OSC = OSC_INTRO .. OSC_TEXT .. "$"

local contexts = {}
local generation = 0
local mode = "filter"
local osc_kind = "render"
local osc_handlers = {}
---@type table?
local baleia_instance = nil
local fast_render = nil
---@type table?
local stream_render = nil
local strip_sgr_codes = true
local initialized = false
-- Baleia uses the supplied name for both its namespace and highlight groups.
-- Keep its marks separate from other consumers of Baleia in the same buffer.
local baleia_namespaces = {}

local M = {}

M.ns_id = vim.api.nvim_create_namespace("compile-mode-ansi-osc")
vim.api.nvim_set_hl(0, "CompileModeUrl", { underline = true, sp = "#569cd6" })

vim.api.nvim_create_autocmd("BufWipeout", {
	group = vim.api.nvim_create_augroup("compile-mode-ansi-state", { clear = true }),
	callback = function(ev)
		contexts[ev.buf] = nil
	end,
})

---@param config CompileModeConfig
local function setup(config)
	local ansi_cfg = config.ansi_color
	mode = ansi_cfg.kind
	if mode == "render" then
		local ok, baleia_mod = pcall(require, "baleia")
		if ok then
			local options = vim.tbl_extend("force", {}, ansi_cfg.baleia_options or {})
			options.name = "compile-mode-" .. (options.name or "BaleiaColors")
			baleia_namespaces[vim.api.nvim_create_namespace(options.name)] = true
			baleia_instance = baleia_mod.setup(options)
			fast_render = require("compile-mode.ansi_fast").create(options, baleia_instance)
			stream_render = require("compile-mode.ansi_render").create(options, baleia_instance)
			strip_sgr_codes = options.strip_ansi_codes ~= false
		else
			log.warn("ansi_color.kind is 'render' but baleia.nvim could not be loaded. Falling back to 'filter'.")
			mode = "filter"
		end
	end

	local osc_cfg = config.ansi_osc
	osc_kind = osc_cfg.kind
	local defaults = {}
	if osc_kind == "render" then
		defaults = {
			[0] = function(ctx)
				vim.opt.titlestring = ctx.data
				vim.opt.iconstring = ctx.data
				return ""
			end,
			[1] = function(ctx)
				vim.opt.iconstring = ctx.data
				return ""
			end,
			[2] = function(ctx)
				vim.opt.titlestring = ctx.data
				return ""
			end,
			[9] = function(ctx)
				vim.notify(ctx.data, vim.log.levels.INFO)
				return ""
			end,
			[8] = function(ctx)
				local uri = ctx.data:match(";%s*(.*)")
				if uri and uri ~= "" then
					return "", { link_open = { uri = uri } }
				end
				return "", { link_close = true }
			end,
		}
	end
	osc_handlers = vim.tbl_extend("keep", osc_cfg.handlers or {}, defaults)
end

---Remove colors before replacing their text, including marks queued by Baleia.
---The deferred clear must be queued before the next Baleia write schedules marks.
---@param bufnr integer
---@param start integer
---@param end_ integer
local function clear_colors(bufnr, start, end_)
	for ns in pairs(baleia_namespaces) do
		vim.api.nvim_buf_clear_namespace(bufnr, ns, start, end_)
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_clear_namespace(bufnr, ns, start, end_)
			end
		end)
	end
end

---Strip all CSI sequences (SGR and non-SGR) from a line.
---@param line string
---@return string
local function strip_csi(line)
	return (line:gsub(CSI_COMPLETE, ""))
end

---Strip non-SGR CSI sequences from a line, keeping SGR (color) sequences intact.
---@param line string
---@return string
local function strip_non_sgr_csi(line)
	return (line:gsub(CSI_NON_SGR, ""))
end

---Strip all OSC sequences from a line.
---@param line string
---@return string
local function strip_osc(line)
	return (line:gsub(OSC_BEL_TERM, ""):gsub(OSC_ST_TERM, ""))
end

---@class AnsiOscLinkState
---@field open { uri: string, row: integer, col: integer }?
---@field pending AnsiOscExtmark[]

-- Count visible bytes incrementally, including SGR sequences assembled from
-- handler replacements and later text. An unfinished sequence counts as text
-- until its final `m` arrives, matching stripping the assembled prefix.
local function visible_len(text, control)
	local visible, pos = #text, 1
	while pos <= #text do
		if not control.phase then
			local escape = text:find(ESC, pos, true)
			if not escape then
				break
			end
			control.phase, control.length = 1, 1
			pos = escape + 1
		else
			local byte = text:byte(pos)
			if control.phase == 1 and byte == 91 then
				control.phase, control.length = 2, control.length + 1
			elseif control.phase == 2 and byte >= 48 and byte <= 63 then
				control.length = control.length + 1
			elseif control.phase >= 2 and byte >= 32 and byte <= 47 then
				control.phase, control.length = 3, control.length + 1
			else
				if control.phase >= 2 and byte == 109 and (mode ~= "render" or strip_sgr_codes) then
					visible = visible - control.length - 1
				end
				control.phase = byte == 27 and 1 or nil
				control.length = 1
			end
			pos = pos + 1
		end
	end
	return visible
end

---Walk through line manually tracking positions, process OSC sequences.
---Returns cleaned line. Side-effects: modifies link_state for extmark placement.
---@param line string
---@param bufnr integer
---@param row integer 0-indexed absolute row in buffer
---@param link_state AnsiOscLinkState
---@return string
local function process_osc(line, bufnr, row, link_state, events, previous, reusable)
	local pieces = {}
	local pos, column = 1, 0
	local control = {}

	while pos <= #line do
		local osc_start = string.find(line, OSC_INTRO, pos)
		if not osc_start then
			break
		end

		local before = line:sub(pos, osc_start - 1)
		table.insert(pieces, before)
		column = column + visible_len(before, control)

		-- Scan each byte at most once. Searching independently for BEL and ST
		-- repeatedly rescans the remainder when only one kind is present.
		local terminator = line:find("[\7\27]", osc_start + 2)
		while terminator and line:byte(terminator) == 27 and line:byte(terminator + 1) ~= 92 do
			terminator = line:find("[\7\27]", terminator + 1)
		end
		if not terminator then
			table.insert(pieces, line:sub(osc_start))
			pos = #line + 1
			break
		end
		local body = line:sub(osc_start + 2, terminator - 1)
		local body_end = terminator + (line:byte(terminator) == 27 and 1 or 0)

		local semicolon = string.find(body, ";")
		if semicolon then
			local cmd = tonumber(body:sub(1, semicolon - 1))
			local data = body:sub(semicolon + 1)
			local handler = cmd and osc_handlers[cmd]
			if handler then
				local cached = previous and previous[osc_start]
				local text, meta
				if cached and body_end <= reusable and cached.source == line:sub(osc_start, body_end) then
					text, meta = cached.text, cached.meta
				else
					text, meta = handler({ bufnr = bufnr, data = data })
				end
				if events then
					events[osc_start] = { source = line:sub(osc_start, body_end), text = text, meta = meta }
				end
				if meta then
					if meta.link_open then
						link_state.open = {
							uri = meta.link_open.uri,
							row = row,
							col = column,
						}
					elseif meta.link_close and link_state.open then
						table.insert(link_state.pending, {
							start_row = link_state.open.row,
							start_col = link_state.open.col,
							end_row = row,
							end_col = column,
							url = link_state.open.uri,
						})
						link_state.open = nil
					end
				end
				if text and text ~= "" then
					table.insert(pieces, text)
					column = column + visible_len(text, control)
				end
			end
		end

		pos = body_end + 1
	end

	local rest = line:sub(pos)
	table.insert(pieces, rest)
	column = column + visible_len(rest, control)
	-- Finish the visible part of an open link on this row, carrying only its
	-- URI into the next row. Marks never span another stream's inserted rows.
	if link_state.open and column > link_state.open.col then
		table.insert(link_state.pending, {
			start_row = row,
			start_col = link_state.open.col,
			end_row = row,
			end_col = column,
			url = link_state.open.uri,
		})
	end
	return table.concat(pieces)
end

---Check if a line ends with a partial escape sequence.
---@param line string
---@return integer|nil start_pos 1-indexed byte position where partial begins, or nil
local function check_partial(line)
	local csi = string.find(line, PARTIAL_CSI)
	if not csi then
		csi = string.find(line, LONE_ESC)
	end
	local osc = string.find(line, PARTIAL_OSC) or string.find(line, OSC_INTRO .. OSC_TEXT .. ESC .. "$")
	if csi and osc then
		return math.min(csi, osc)
	elseif csi then
		return csi
	elseif osc then
		return osc
	end
	return nil
end

---@alias AnsiOscExtmark { start_row: integer, start_col: integer, end_row: integer, end_col: integer, url: string }

---Place pending URL extmarks from link tracking.
---@param bufnr integer
---@param pending AnsiOscExtmark[]
local function apply_osc_extmarks(bufnr, pending)
	for _, em in ipairs(pending) do
		local ok, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_id, em.start_row, em.start_col, {
			end_row = em.end_row,
			end_col = em.end_col,
			url = em.url,
			hl_group = "CompileModeUrl",
		})
		if not ok then
			log.fmt_warn("failed to place URL extmark: %s", err)
		end
	end
end

---The optional stream table is owned by the caller and can be used for stdout
---and stderr separately. All retained metadata belongs to its unfinished row.
local function context(bufnr, supplied)
	local ctx = supplied or contexts[bufnr] or {}
	if not supplied then
		contexts[bufnr] = ctx
	end
	if ctx._generation ~= generation or ctx._buffer ~= bufnr then
		ctx._generation, ctx._buffer = generation, bufnr
		ctx._partial, ctx._tail, ctx._after = "", nil, {}
	end
	return ctx
end

local function common_prefix(left, right)
	local limit = math.min(#left, #right)
	local i = 1
	while i <= limit and left:byte(i) == right:byte(i) do
		i = i + 1
	end
	return i - 1
end

---@param bufnr integer
---@param start integer
---@param end_ integer
---@param lines string[]
---@param replay_partial? boolean normalized lines already contain the raw unfinished tail
---@param supplied? table independent stream state; recreated for every job
function M.buf_set_lines(bufnr, start, end_, lines, replay_partial, supplied)
	if not initialized then
		setup(require("compile-mode.config.internal"))
		initialized = true
	end
	local ctx = context(bufnr, supplied)
	local count = vim.api.nvim_buf_line_count(bufnr)
	start = math.max(0, math.min(count, start < 0 and count + start + 1 or start))
	end_ = math.max(0, math.min(count, end_ < 0 and count + end_ + 1 or end_))
	if start < end_ then
		clear_colors(bufnr, start, end_)
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id, start, end_)
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	if mode == "passthrough" or #lines == 0 then
		vim.api.nvim_buf_set_lines(bufnr, start, end_, false, lines)
	else
		local tail = ctx._tail
		local replay = replay_partial and tail and tail.row == start
		local before = replay and tail.before or (tail and start > tail.row and ctx._after or {})
		if replay and ctx.replay_reset then
			before = ctx._after
		end
		local reusable = replay and (ctx.replay_prefix or common_prefix(tail.raw, lines[1])) or 0
		if ctx.replay_reset then
			reusable = 0
		end
		local previous = replay and tail.events or nil
		local raw_lines = vim.list_slice(lines)
		if not replay_partial then
			raw_lines[1] = ctx._partial .. raw_lines[1]
		end
		local previous_partial = ctx._partial
		ctx._partial = ""
		local cleaned, rows, definitions, pending = {}, {}, {}, {}
		local style, link = before.style, before.link
		for i, raw in ipairs(raw_lines) do
			local row = start + i - 1
			local strip = mode == "filter" and strip_csi or strip_non_sgr_csi
			local discarded = ctx.discarded_prefixes and ctx.discarded_prefixes[i]
				or (i == 1 and ctx.discarded_prefix or nil)
			if discarded and discarded ~= "" then
				if i == 1 then
					discarded = previous_partial .. discarded
				end
				local discarded_links = { open = link and { uri = link, row = row, col = 0 }, pending = {} }
				discarded = strip(discarded)
				if osc_kind ~= "passthrough" then
					discarded = process_osc(discarded, bufnr, row, discarded_links)
				end
				link = discarded_links.open and discarded_links.open.uri or nil
				if mode == "render" and stream_render then
					local ignored
					ignored, style = stream_render.line(discarded, style)
				end
			end
			local row_before = i == #raw_lines and { style = style, link = link }
			local line = raw
			if i == #raw_lines then
				local partial = check_partial(line)
				if partial then
					ctx._partial = line:sub(partial)
					line = line:sub(1, partial - 1)
				end
			end
			line = strip(line)
			local events
			if osc_kind ~= "passthrough" and (link or line:find(ESC .. "]", 1, true)) then
				events = {}
				local links = { open = link and { uri = link, row = row, col = 0 }, pending = pending }
				line = process_osc(
					line,
					bufnr,
					row,
					links,
					events,
					i == 1 and previous or nil,
					i == 1 and #strip(raw:sub(1, reusable)) or 0
				)
				link = links.open and links.open.uri or nil
			end
			if mode == "render" and stream_render then
				line, style, rows[i] = stream_render.line(line, style, definitions)
			end
			cleaned[i] = line
			if i == #raw_lines then
				ctx._tail = { row = row, raw = raw, before = row_before, events = events }
			end
		end
		ctx._after = { style = style, link = link }
		if mode == "render" and not stream_render then
			if not fast_render or not fast_render(bufnr, start, end_, cleaned) then
				assert(baleia_instance).buf_set_lines(bufnr, start, end_, false, cleaned)
			end
		else
			if mode == "render" and stream_render then
				stream_render.write(bufnr, start, end_, cleaned)
				stream_render.apply(bufnr, start, rows, definitions)
			else
				vim.api.nvim_buf_set_lines(bufnr, start, end_, false, cleaned)
			end
		end
		apply_osc_extmarks(bufnr, pending)
	end
	ctx.replay_prefix, ctx.replay_reset = nil, nil
	ctx.discarded_prefix, ctx.discarded_prefixes = nil, nil
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
		end
	end)
end

---Reset escape state and remove our highlights from a reused compilation buffer.
---@param bufnr? integer
function M.reset(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		clear_colors(bufnr, 0, -1)
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id, 0, -1)
	end
	initialized = false
	generation = generation + 1
	contexts = {}
	baleia_instance = nil
	fast_render = nil
	stream_render = nil
end

---Flush any remaining partial buffer to the compilation buffer.
---Call this when the process exits, before writing the footer.
---@param bufnr integer
function M.flush(bufnr, supplied)
	local ctx = context(bufnr, supplied)
	if ctx._partial == "" then
		return
	end
	local line = ctx._partial
	ctx._partial = ""
	local row = ctx._tail and ctx._tail.row or vim.api.nvim_buf_line_count(bufnr) - 1
	local last = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	if not last then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_text(bufnr, row, #last, row, #last, { line })
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
		end
	end)
end

M._strip_csi = strip_csi
M._strip_non_sgr_csi = strip_non_sgr_csi
M._strip_osc = strip_osc
M._strip_sgr = function(line)
	return (line:gsub(CSI_SGR, ""))
end

return M
