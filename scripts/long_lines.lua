-- Fragmented, unterminated lines: compare unchanged final output and total replay work.
-- Copy this file into the reference checkout to measure the pre-stream runtime.
local s = require("scripts.support")
local samples = tonumber(vim.env.BENCH_SAMPLES) or 5
local cases = {}
local threshold, fragment_size = 65536, 256
local fragment = string.rep("x", fragment_size)

local function replay_bound(count)
	-- Short prefixes still update live; that fixed initial cost is bounded.
	local short = threshold / fragment_size
	return fragment_size * short * (short + 1) / 2 + 3 * count * fragment_size
end

for _, count in ipairs({ 1000, 2000, 4000 }) do
	for _, stage in ipairs({ "normalization", "pipeline" }) do
		local name = stage .. "/" .. count
		cases[name] = function()
			s.setup()
			local output = require("compile-mode.output")
			local optimized = output.new_stream ~= nil
			local counters
			local result = s.measure(name, count, function()
				return {}
			end, function()
				counters = { writes = 0, replayed_bytes = 0 }
				local function count_lines(lines)
					if #lines > 0 then
						counters.writes = counters.writes + 1
						for _, line in ipairs(lines) do
							counters.replayed_bytes = counters.replayed_bytes + #line
						end
					end
				end
				if stage == "normalization" then
					local stream = optimized and output.new_stream({})
					local tail, final = "", ""
					for _ = 1, count do
						local lines
						if stream then
							lines = stream.push({ fragment })
						else
							lines, tail = output.normalize({ fragment }, tail, {})
						end
						count_lines(lines)
						final = lines[1] or final
					end
					if stream then
						local lines = stream.flush()
						count_lines(lines)
						final = lines[1] or final
					end
					return final
				end

				local ansi = require("compile-mode.ansi")
				local writer, jobstart = ansi.buf_set_lines, vim.fn.jobstart
				local callbacks
				---@diagnostic disable-next-line: duplicate-set-field
				ansi.buf_set_lines = function(buf, start, end_, lines, replay, context)
					count_lines(lines)
					return writer(buf, start, end_, lines, replay, context)
				end
				vim.fn.jobstart = function(_, opts)
					callbacks = opts
					return 987654
				end
				local ok, ev = xpcall(function()
					return s.compile("fragmented output benchmark", function()
						assert(vim.wait(5000, function()
							return callbacks ~= nil
						end, 1))
						for _ = 1, count do
							callbacks.on_stdout(987654, { fragment })
							-- Drain before the next callback: queue coalescing cannot
							-- hide repeated-prefix work in this workload.
							local drained = false
							vim.defer_fn(function()
								vim.defer_fn(function()
									drained = true
								end, 0)
							end, 0)
							assert(vim.wait(5000, function()
								return drained
							end, 1))
							s.drain()
						end
						callbacks.on_exit(987654, 0)
					end)
				end, debug.traceback)
				ansi.buf_set_lines, vim.fn.jobstart = writer, jobstart
				assert(ok, ev)
				return vim.api.nvim_buf_get_lines(ev.bufnr, 4, 5, false)[1]
			end, function(_, text)
				assert(text == string.rep(fragment, count), "final output differs")
				if optimized then
					assert(counters.replayed_bytes <= replay_bound(count), "prefix replay exceeded the linear bound")
				end
			end, samples)
			result.input_bytes = count * fragment_size
			result.fragment_bytes = fragment_size
			result.stream = optimized
			result.writes = counters.writes
			result.replayed_bytes = counters.replayed_bytes
			result.passed = true
			return result
		end
	end
end

local name = arg[1]
if name == "list" then
	s.finish(vim.tbl_keys(cases))
else
	local ok, result = pcall(assert(cases[name], "unknown case: " .. tostring(name)))
	s.finish(ok and result or { name = name, passed = false, error = tostring(result) })
end
