-- Accelerate independent whole-line colors without reimplementing Baleia's styles.
-- Optional private helpers are shape-checked; unsupported versions and layouts
-- keep using Baleia's public writer.
local M = {}
local ESC = "\27"
local RESET = ESC .. "[0m"

function M.create(options, renderer)
	if
		not renderer.logger
		or options.strip_ansi_codes == false
		or (options.line_starts_at and options.line_starts_at ~= 1)
		or options.log
	then
		return nil
	end
	local ok, highlight = pcall(require, "baleia.highlight")
	local options_ok, baleia_options = pcall(require, "baleia.options")
	if
		not ok
		or not options_ok
		or type(highlight) ~= "table"
		or type(baleia_options) ~= "table"
		or type(highlight.all) ~= "function"
		or type(baleia_options.with_default) ~= "function"
	then
		return nil
	end
	local opts_ok, opts = pcall(baleia_options.with_default, options)
	if not opts_ok or type(opts) ~= "table" then
		return nil
	end
	local ns = vim.api.nvim_create_namespace(options.name)
	local plans, plan_count = {}, 0

	local function plan(prefix)
		if plans[prefix] ~= nil then
			return plans[prefix]
		end
		local success, actions = pcall(
			highlight.all,
			opts,
			{ global = { column = 0, line = 0 } },
			{ prefix .. "x" .. RESET }
		)
		local found
		if
			success
			and type(actions) == "table"
			and type(actions.highlights) == "table"
			and type(actions.definitions) == "table"
		then
			for _, span in ipairs(actions.highlights) do
				if type(span) ~= "table" then
					return false
				end
				if
					span.line == 1
					and span.firstcolumn == 1
					and span.lastcolumn == 1
					and type(actions.definitions[span.name]) == "table"
					and not found
				then
					found = { name = span.name, attributes = actions.definitions[span.name] }
				elseif span.line ~= 1 or span.firstcolumn ~= 2 or span.lastcolumn ~= nil then
					return false
				end
			end
		end
		-- Bound retention for true-color streams with a different color per row.
		if plan_count >= 128 then
			plans, plan_count = {}, 0
		end
		plan_count = plan_count + 1
		plans[prefix] = found or false
		return found
	end

	return function(bufnr, start, end_, lines)
		local cleaned, spans, definitions = {}, {}, {}
		local colored, plain = false, false
		for i, line in ipairs(lines) do
			if not line:find(ESC, 1, true) then
				cleaned[i] = line
				plain = plain or #line > 0
			else
				colored = true
				local prefix = line:match("^(\27%[[%d;:]+m)")
				if not prefix or line:sub(-#RESET) ~= RESET then
					return false
				end
				local closing = line:find(ESC, #prefix + 1, true)
				if closing ~= #line - #RESET + 1 then
					return false
				end
				local style = plan(prefix)
				if not style then
					return false
				end
				local body = line:sub(#prefix + 1, closing - 1)
				cleaned[i] = body
				if #body > 0 then
					spans[#spans + 1] = { row = start + i - 1, length = #body, name = style.name }
					definitions[style.name] = style.attributes
				end
			end
		end
		-- A reset may cover subsequent plain rows. Keep that multi-line
		-- behavior with Baleia instead of eliding its reset attributes.
		if colored and plain then
			return false
		end
		vim.api.nvim_buf_set_lines(bufnr, start, end_, false, cleaned)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			for name, attributes in pairs(definitions) do
				pcall(vim.api.nvim_set_hl, 0, name, attributes)
			end
			for _, span in ipairs(spans) do
				-- A later queued write may already have replaced these rows.
				pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, span.name, span.row, 0, span.length)
			end
		end)
		return true
	end
end

return M
