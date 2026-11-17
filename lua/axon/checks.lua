-- `# @assert`, `# @warn` and `# @notice` results: counting them for the
-- response window and reporting failures as diagnostics in the .http buffer.
local M = {}

M.ns = vim.api.nvim_create_namespace("axon.checks")

M.levels = {
	assert = { icon = "✗", hl = "DiagnosticError", severity = vim.diagnostic.severity.ERROR },
	warn = { icon = "⚠", hl = "DiagnosticWarn", severity = vim.diagnostic.severity.WARN },
	notice = { icon = "ℹ", hl = "DiagnosticInfo", severity = vim.diagnostic.severity.INFO },
}
M.order = { "assert", "warn", "notice" }

--- Counts a response's checks: `total`, and failures per level.
---@return { total: integer, failed: integer, assert: integer, warn: integer, notice: integer }
function M.count(response)
	local counts = { total = 0, failed = 0, assert = 0, warn = 0, notice = 0 }
	for _, check in ipairs(response.checks or {}) do
		counts.total = counts.total + 1
		if not check.ok and counts[check.level] then
			counts[check.level] = counts[check.level] + 1
			counts.failed = counts.failed + 1
		end
	end
	return counts
end

--- The failed checks of a response, most severe first.
function M.failures(response)
	local failed = {}
	for _, level in ipairs(M.order) do
		for _, check in ipairs(response.checks or {}) do
			if not check.ok and check.level == level then
				table.insert(failed, check)
			end
		end
	end
	return failed
end

-- The row of the `@level text` line in rows first..last, or nil.
local function find_check(lines, first, last, level, text)
	for row = first, last do
		local line = lines[row + 1]
		if line then
			local rest = vim.trim(line)
			rest = rest:match("^#(.*)") or rest:match("^//(.*)")
			rest = rest and vim.trim(rest):match("^@" .. level .. "%s+(.*)$")
			if rest and vim.trim(rest) == text then
				return row
			end
		end
	end
end

--- Reports the failed checks and skipped requests of a run as diagnostics in
--- `bufnr`, replacing those of the previous run. `listing` is every request
--- in the buffer, so the checks of dependencies are found too.
---@param bufnr integer
---@param entries table[] flattened responses (see init.lua)
---@param listing axon.Request[]
function M.report(bufnr, entries, listing)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local by_index, by_selector = {}, {}
	for _, request in ipairs(listing or {}) do
		by_index[request.index] = request
		by_selector[request.selector] = request
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- One diagnostic per line; a looping request adds one message per element.
	local by_row, rows = {}, {}
	local function add(row, level, message)
		local diag = by_row[row]
		if not diag then
			diag = { lnum = row, col = 0, severity = M.levels[level].severity, source = "axon", messages = {} }
			by_row[row] = diag
			table.insert(rows, row)
		end
		diag.severity = math.min(diag.severity, M.levels[level].severity)
		table.insert(diag.messages, message)
	end

	for _, entry in ipairs(entries) do
		if entry.skipped then
			local request = by_selector[entry.label]
			if request then
				add(request.start_row, "notice", "skipped: " .. entry.reason)
			end
		else
			local request = by_index[entry.index]
			if request then
				for _, check in ipairs(entry.checks or {}) do
					if not check.ok then
						local row = find_check(lines, request.start_row, request.end_row, check.level, check.check)
							or request.start_row
						local message = string.format("@%s %s: %s", check.level, check.check, check.error or "failed")
						if entry.element then
							message = string.format("[%d] %s", entry.element, message)
						end
						add(row, check.level, message)
					end
				end
			end
		end
	end

	local diagnostics = {}
	table.sort(rows)
	for _, row in ipairs(rows) do
		local diag = by_row[row]
		diag.message = table.concat(diag.messages, "\n")
		diag.messages = nil
		table.insert(diagnostics, diag)
	end
	vim.diagnostic.set(M.ns, bufnr, diagnostics)
end

function M.clear(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.diagnostic.reset(M.ns, bufnr)
	end
end

return M
