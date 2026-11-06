local s = require("scripts.support")
local cases = {}
local samples = tonumber(vim.env.BENCH_SAMPLES) or 7
local sizes = vim.tbl_map(tonumber, vim.split(vim.env.BENCH_SIZES or "1000,10000", ","))

local function lines(kind, count)
	local result = {}
	for i = 1, count do
		if kind == "errors" or (kind == "mixed" and i % 10 == 0) then
			result[i] = ("file.c:%d:1: error: failure"):format(i)
		elseif kind == "ansi" then
			result[i] = ("\27[32mbuild %d\27[0m\27[K"):format(i)
		elseif kind == "control" then
			result[i] = "old\rprogress\n update\r"
		else
			result[i] = ("build step %d complete"):format(i)
		end
	end
	return result
end

local function reset()
	require("compile-mode.state").reset()
end

local function prepare_errors(data)
	reset()
	local errors = require("compile-mode.errors")
	local buf = s.buffer(data)
	for i, line in ipairs(data) do
		errors.error_list[i] = assert(errors.parse(line, i))
	end
	return { buf = buf, errors = errors.error_list }
end

local function register(name, count, fn)
	cases[name .. "/" .. count] = function()
		local result = fn(count)
		result.name = name .. "/" .. count
		result.input_size = count
		result.passed = true
		return result
	end
end

for _, count in ipairs(sizes) do
	for _, kind in ipairs({ "plain", "control" }) do
		register("output/" .. kind, count, function(n)
			s.setup()
			local output = require("compile-mode.output")
			local data = lines(kind, n)
			return s.measure("normalize", n, function()
				return {}
			end, function()
				return output.normalize(data, "", { "^hidden.*", "password=[^ ]*" })
			end, function(_, result)
				s.equal(n, #result)
			end, samples)
		end)
	end

	for _, kind in ipairs({ "plain", "mixed", "errors" }) do
		register("parse/" .. kind, count, function(n)
			s.setup()
			local errors = require("compile-mode.errors")
			local data = lines(kind, n)
			return s.measure("errors.parse", n, function()
				return {}
			end, function()
				local found = 0
				for i, line in ipairs(data) do
					if errors.parse(line, i) then
						found = found + 1
					end
				end
				return found
			end, function(_, result)
				s.equal(kind == "errors" and n or kind == "mixed" and math.floor(n / 10) or 0, result)
			end, samples)
		end)

		register("scan/" .. kind, count, function(n)
			s.setup()
			local parser = require("compile-mode.parser")
			local data = lines(kind, n)
			return s.measure("parser.scan", n, function()
				reset()
				return { buf = s.buffer(data) }
			end, function(ctx)
				return parser.scan(ctx.buf, 0, -1)
			end, function()
				s.equal(
					kind == "errors" and n or kind == "mixed" and math.floor(n / 10) or 0,
					vim.tbl_count(require("compile-mode.errors").error_list)
				)
			end, samples)
		end)
	end

	for _, mode in ipairs({ "filter", "render", "passthrough" }) do
		register("ansi/" .. mode, count, function(n)
			s.setup({ ansi_color = { kind = mode, baleia_options = {} } })
			if mode == "render" then
				assert(pcall(require, "baleia"), "baleia is required")
			end
			local ansi = require("compile-mode.ansi")
			local data = lines("ansi", n)
			return s.measure("ansi.buf_set_lines", n, function()
				ansi.reset()
				return { buf = s.buffer({ "" }), data = vim.deepcopy(data) }
			end, function(ctx)
				ansi.buf_set_lines(ctx.buf, 0, -1, ctx.data)
				s.drain()
			end, function(ctx)
				s.equal(n, vim.api.nvim_buf_line_count(ctx.buf))
				local first = vim.api.nvim_buf_get_lines(ctx.buf, 0, 1, false)[1]
				s.equal(mode == "passthrough" and data[1] or "build 1", first)
			end, samples)
		end)
	end

	register("buffer/write", count, function(n)
		s.setup()
		local data = lines("plain", n)
		return s.measure("buffer.set_lines", n, function()
			return { buf = s.buffer({ "" }) }
		end, function(ctx)
			require("compile-mode.buffer").set_lines(ctx.buf, 0, -1, data)
			s.drain()
		end, function(ctx)
			s.equal(n, vim.api.nvim_buf_line_count(ctx.buf))
		end, samples)
	end)

	register("render/fresh", count, function(n)
		s.setup()
		local data = lines("errors", n)
		return s.measure("parser.render", n, function()
			return prepare_errors(data)
		end, function(ctx)
			require("compile-mode.parser").render(ctx.buf, {})
		end, function(ctx)
			local ns = vim.api.nvim_create_namespace("compile-mode.nvim")
			s.equal(n * 4, #vim.api.nvim_buf_get_extmarks(ctx.buf, ns, 0, -1, {}))
		end, samples)
	end)

	register("render/already_highlighted", count, function(n)
		s.setup()
		local errors = require("compile-mode.errors")
		local data = lines("errors", n)
		return s.measure("100 visits to highlighted errors", 100, function()
			local ctx = prepare_errors(data)
			errors.highlight(ctx.buf)
			return ctx
		end, function(ctx)
			for _ = 1, 100 do
				errors.highlight(ctx.buf)
			end
		end, nil, samples)
	end)

	for _, chunk in ipairs({ 1, 100 }) do
		register("incremental/chunk_" .. chunk, count, function(n)
			s.setup()
			local parser = require("compile-mode.parser")
			local data = lines("errors", n)
			return s.measure("incremental scan/render", n, function()
				reset()
				return { buf = s.buffer(data) }
			end, function(ctx)
				for start = 0, n - 1, chunk do
					parser.parse(ctx.buf, start, math.min(start + chunk, n))
				end
			end, function()
				s.equal(n, vim.tbl_count(require("compile-mode.errors").error_list))
			end, samples)
		end)
	end

	for _, operation in ipairs({ "statusline", "navigation", "quickfix", "diagnostics", "trim" }) do
		register("metadata/" .. operation, count, function(n)
			s.setup()
			local errors = require("compile-mode.errors")
			local data = lines("errors", n)
			local source = vim.fn.bufadd(vim.fn.getcwd() .. "/file.c")
			local repetitions = (operation == "statusline" or operation == "navigation") and 100 or 1
			return s.measure(operation, repetitions, function()
				local ctx = prepare_errors(data)
				vim.api.nvim_set_current_buf(ctx.buf)
				return ctx
			end, function()
				local result
				for _ = 1, repetitions do
					if operation == "statusline" then
						result = require("compile-mode.statusline").info()
					elseif operation == "navigation" then
						require("compile-mode.state").error_cursor = 0
						require("compile-mode.navigation").move_to_next_error({ smods = { silent = true } })
						result = vim.api.nvim_win_get_cursor(0)[1]
					elseif operation == "quickfix" then
						result = errors.toqflist(errors.error_list)
					elseif operation == "diagnostics" then
						result = errors.todiagnostic(source, errors.error_list)
					else
						require("compile-mode.state").trim_lines(1)
					end
				end
				return result
			end, function(_, result)
				if operation == "statusline" then
					s.equal(n, result.counts.error)
				elseif operation == "navigation" then
					s.equal(1, result)
				elseif operation == "quickfix" or operation == "diagnostics" then
					s.equal(n, #result)
				else
					s.equal(n - 1, vim.tbl_count(errors.error_list))
				end
			end, samples)
		end)
	end
end

for _, transitions in ipairs({ 1, 100, 1000 }) do
	register("directory/1000_lookups", transitions, function(n)
		s.setup()
		local dir = require("compile-mode.dir")
		for i = 1, n do
			dir.dir_changes[i * 2] = "/build/" .. i
		end
		return s.measure("directory lookup", 1000, function()
			return {}
		end, function()
			local result
			for _ = 1, 1000 do
				result = dir.find_directory_for_line(n * 2 + 1)
			end
			return result
		end, function(_, result)
			s.equal("/build/" .. n, result)
		end, samples)
	end)
end

for _, length in ipairs({ 32, 512, 4096 }) do
	register("regex/100_long_nonmatches", length, function(n)
		s.setup()
		local errors = require("compile-mode.errors")
		local line = string.rep("x", n)
		return s.measure("long nonmatches", 100, function()
			return {}
		end, function()
			for _ = 1, 100 do
				assert(not errors.parse(line, 1))
			end
		end, nil, samples)
	end)
end

local stream_kinds = { "plain", "errors", "ansi" }
if vim.env.BENCH_LOG then
	stream_kinds[#stream_kinds + 1] = "log"
end
for _, kind in ipairs(stream_kinds) do
	local count = kind == "log" and #vim.fn.readfile(vim.env.BENCH_LOG) or sizes[#sizes]
	register("end_to_end/" .. kind, count, function(n)
		s.setup({ ansi_color = { kind = kind == "ansi" and "render" or "filter", baleia_options = {} } })
		if kind == "ansi" then
			assert(pcall(require, "baleia"), "baleia is required")
		end
		local command = kind == "log" and ("cat " .. vim.fn.shellescape(vim.env.BENCH_LOG))
			or s.command("scripts/producer.lua", kind, tostring(n))
		local lags = {}
		local callbacks = {}
		local extmarks = {}
		local runs = 0
		local stages = {}
		local stage_samples = {}
		local originals = {}
		local callback_count = 0
		for _, target in ipairs({
			{ "output", "normalize" },
			{ "ansi", "buf_set_lines" },
			{ "parser", "scan" },
			{ "parser", "render" },
		}) do
			local mod = require("compile-mode." .. target[1])
			local key = target[1] .. "." .. target[2]
			local original = mod[target[2]]
			originals[#originals + 1] = { mod, target[2], original }
			mod[target[2]] = function(...)
				local started = vim.uv.hrtime()
				local values = { original(...) }
				local elapsed = (vim.uv.hrtime() - started) / 1e6
				local stage = stages[key] or { total_ms = 0, max_call_ms = 0, calls = 0 }
				stage.total_ms = stage.total_ms + elapsed
				stage.max_call_ms = math.max(stage.max_call_ms, elapsed)
				stage.calls = stage.calls + 1
				stages[key] = stage
				if key == "output.normalize" then
					callback_count = callback_count + 1
				end
				return unpack(values)
			end
		end
		local result = s.measure("compile wall time including producer startup", n, function()
			callback_count = 0
			stages = {}
			return {}
		end, function()
			local max_gap = 0
			local last = vim.uv.hrtime()
			local timer = assert(vim.uv.new_timer())
			timer:start(
				5,
				5,
				vim.schedule_wrap(function()
					local now = vim.uv.hrtime()
					max_gap = math.max(max_gap, (now - last) / 1e6)
					last = now
				end)
			)
			local ok, ev = pcall(s.compile, command, nil, runs > 0)
			runs = runs + 1
			max_gap = math.max(max_gap, (vim.uv.hrtime() - last) / 1e6)
			timer:stop()
			timer:close()
			assert(ok, ev)
			lags[#lags + 1] = max_gap
			callbacks[#callbacks + 1] = callback_count
			stage_samples[#stage_samples + 1] = stages
			return ev
		end, function(_, ev)
			extmarks[#extmarks + 1] = #vim.api.nvim_buf_get_extmarks(ev.bufnr, -1, 0, -1, {})
			s.equal(0, ev.code)
			s.equal(n + 7, vim.api.nvim_buf_line_count(ev.bufnr), "output lines including header/blank/footer")
		end, samples)
		for _, original in ipairs(originals) do
			original[1][original[2]] = original[3]
		end
		result.synchronous_stages = stage_samples
		result.extmarks_after_each_run = extmarks
		result.reuses_compilation_buffer = true
		result.event_loop_max_gap_ms = lags
		result.normalization_batches = callbacks
		result.includes_warmup_in_auxiliary_samples = true
		if kind == "log" then
			result.input_sha256 = vim.fn.sha256(table.concat(vim.fn.readfile(vim.env.BENCH_LOG), "\n") .. "\n")
		end
		return result
	end)
end

for _, kind in ipairs({ "plain", "long" }) do
	cases["matcher_profile/" .. kind] = function()
		local _, config = s.setup()
		local profiles = {}
		local line = kind == "plain" and "build step 123 complete" or string.rep("x", 4096)
		local iterations = kind == "plain" and 1000 or 100
		local utils = require("compile-mode.utils")
		local keys = vim.tbl_keys(config.error_regexp_table)
		table.sort(keys)
		for _, name in ipairs(keys) do
			local matcher = config.error_regexp_table[name]
			profiles[#profiles + 1] = s.measure(name, iterations, function()
				return {}
			end, function()
				for _ = 1, iterations do
					local result = utils.matchlistpos(line, matcher.regex, matcher._rx)
					assert(not result[1], "profile fixture unexpectedly matched " .. name)
				end
			end, nil, samples)
		end
		table.sort(profiles, function(a, b)
			return a.median_ms > b.median_ms
		end)
		return { name = "matcher_profile/" .. kind, passed = true, profiles = profiles }
	end
end

cases["config/100_validations"] = function()
	local _, config = s.setup()
	return s.measure("config/100_validations", 100, function()
		return {}
	end, function()
		for _ = 1, 100 do
			s.equal({}, require("compile-mode.config.check").get_errors(config))
		end
	end, nil, samples)
end

local name = arg[1]
if name == "list" then
	s.finish(vim.tbl_keys(cases))
else
	local ok, result = xpcall(assert(cases[name], "unknown case: " .. tostring(name)), debug.traceback)
	s.finish(ok and result or { name = name, passed = false, error = result })
end
