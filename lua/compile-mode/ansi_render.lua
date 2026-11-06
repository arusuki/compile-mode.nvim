-- Baleia interprets SGR attributes; this adapter retains its style between writes
-- and keeps every owned mark within one row, so replacing a tail cannot erase
-- an earlier row's color. No raw escape history is retained.
local M = {}

function M.create(options, renderer)
	if type(renderer) ~= "table" or type(renderer.logger) ~= "table" then
		return nil
	end
	local ok, styles = pcall(require, "baleia.styles")
	local options_ok, defaults = pcall(require, "baleia.options")
	local ansi_ok, ansi = pcall(require, "baleia.ansi")
	if
		not ok
		or not options_ok
		or not ansi_ok
		or type(styles) ~= "table"
		or type(defaults) ~= "table"
		or type(ansi) ~= "table"
		or type(styles.none) ~= "function"
		or type(styles.merge) ~= "function"
		or type(styles.to_style) ~= "function"
		or type(styles.name) ~= "function"
		or type(styles.attributes) ~= "function"
		or type(defaults.with_default) ~= "function"
		or type(ansi.PATTERN) ~= "string"
	then
		return nil
	end
	local opts_ok, opts = pcall(defaults.with_default, options)
	if
		not opts_ok
		or type(opts) ~= "table"
		or type(opts.name) ~= "string"
		or type(opts.colors) ~= "table"
		or type(opts.line_starts_at) ~= "number"
		or type(opts.strip_ansi_codes) ~= "boolean"
	then
		return nil
	end
	local compatible = pcall(function()
		local style = styles.merge(styles.none(), styles.to_style("\27[0m"))
		assert(
			type(style.foreground) == "table" and type(style.background) == "table" and type(style.special) == "table"
		)
		assert(type(styles.name(opts.name, style)) == "string")
		assert(type(styles.attributes(style, opts.colors)) == "table")
	end)
	if not compatible then
		return nil
	end
	local ns = vim.api.nvim_create_namespace(opts.name)
	local plans, plan_count = {}, 0
	local transitions, states, state_count, state_id, transition_count = {}, {}, 0, 0, 0
	local function decode(sequence)
		local style = plans[sequence]
		if not style then
			style = styles.to_style(sequence)
			if plan_count >= 128 then
				plans, plan_count = {}, 0
			end
			plans[sequence], plan_count = style, plan_count + 1
		end
		return style
	end

	local function transition(previous, sequence)
		local key = tostring(previous and previous.id or 0) .. sequence
		local cached = transitions[key]
		if cached then
			return cached
		end
		local style = styles.merge(previous and previous.style or styles.none(), decode(sequence))
		local name = styles.name(opts.name, style)
		local identity = name
			.. tostring(style.foreground.set)
			.. tostring(style.background.set)
			.. tostring(style.special.set)
		cached = states[identity]
		if not cached then
			if state_count >= 128 then
				transitions, states, state_count, transition_count = {}, {}, 0, 0
			end
			state_id, state_count = state_id + 1, state_count + 1
			cached = { id = state_id, style = style, name = name, attributes = styles.attributes(style, opts.colors) }
			states[identity] = cached
		end
		if transition_count >= 256 then
			transitions, transition_count = {}, 0
		end
		transitions[key], transition_count = cached, transition_count + 1
		return cached
	end

	local function record(name, success, value, params)
		if opts.log then
			local logger = renderer.logger[success and "debug" or "error"]
			if type(logger) == "function" then
				logger(name, { result = value, params = params })
			end
		end
	end

	return {
		line = function(raw, previous, definitions)
			local style = previous
			definitions = definitions or {}
			local pieces, spans = {}, {}
			-- Whole-line colors remain a common fast path, while transitions are
			-- computed from the inherited style rather than assuming a reset.
			if opts.strip_ansi_codes then
				local prefix = raw:match("^(\27%[[%d;:]+m)")
				if prefix and raw:sub(-4) == "\27[0m" and raw:find("\27", #prefix + 1, true) == #raw - 3 then
					local colored = transition(previous, prefix)
					local body = raw:sub(#prefix + 1, -5)
					if #body > 0 then
						spans[1] = { first = 0, last = #body, name = colored.name }
						definitions[colored.name] = colored.attributes
					end
					return body, transition(colored, "\27[0m"), spans, definitions
				end
			end
			local pos, column = 1, 0
			local inherited_start = previous and math.max(0, opts.line_starts_at - 1) or 0
			local function append(text)
				pieces[#pieces + 1] = text
				local length = #text
				if style and column + length > math.max(column, inherited_start) then
					local name = style.name
					definitions[name] = style.attributes
					spans[#spans + 1] =
						{ first = math.max(column, inherited_start), last = column + length, name = name }
				end
				column = column + length
			end
			while pos <= #raw do
				local first, last = raw:find(ansi.PATTERN, pos)
				if not first then
					break
				end
				append(raw:sub(pos, first - 1))
				-- In raw mode the escape bytes themselves are not colored, matching
				-- Baleia's ignore_ansi_codes coordinate convention.
				if not opts.strip_ansi_codes then
					local sequence = raw:sub(first, last)
					pieces[#pieces + 1] = sequence
					column = column + #sequence
				end
				style = transition(style, raw:sub(first, last))
				inherited_start = 0
				pos = last + 1
			end
			append(raw:sub(pos))
			return table.concat(pieces), style, spans, definitions
		end,
		write = function(bufnr, start, end_, lines)
			vim.api.nvim_buf_set_lines(bufnr, start, end_, false, lines)
			record("vim.api.nvim_buf_set_lines", true, nil, { bufnr, start, end_, false, lines })
		end,
		apply = function(bufnr, start, rows, definitions)
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				for name, attributes in pairs(definitions) do
					local success, value = pcall(vim.api.nvim_set_hl, 0, name, attributes)
					record("vim.api.nvim_set_hl", success, value, { 0, name, attributes })
				end
				for i, spans in ipairs(rows) do
					for _, span in ipairs(spans) do
						local mark = { end_col = span.last, hl_group = span.name }
						local success, value =
							pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, start + i - 1, span.first, mark)
						record(
							"vim.api.nvim_buf_set_extmark",
							success,
							value,
							{ bufnr, ns, start + i - 1, span.first, mark }
						)
					end
				end
			end)
		end,
	}
end

return M
