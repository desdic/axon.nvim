local parser = require("axon.parser")
local ui = require("axon.ui")
local checks = require("axon.checks")

local M = {}

M.cli_version = "0.5"

local defaults = {
	cmd = "axon-cli",
	args = {},
	split = "botright vsplit", -- command used to open the response window
	format_json = true,
	jq = "jq",
	strict = false, -- pass --strict: a failed @warn fails the run like @assert
	diagnostics = true, -- show failed checks as diagnostics in the .http buffer
	keymaps = {
		toggle_headers = "H",
		rerun = "R",
		close = "q",
		-- in the summary after :AxonRunAll
		open = "<CR>",
		back = "<BS>",
	},
}

M.config = vim.deepcopy(defaults)

local last -- { bufnr = integer, request = axon.Request } or { bufnr = integer, all = true }

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function source_file(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path ~= "" and not vim.bo[bufnr].modified then
		return path, nil
	end
	local tmp = vim.fn.tempname() .. ".http"
	vim.fn.writefile(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), tmp)
	return tmp, tmp
end

local function display_name(request)
	return request.selector
end

-- The requests axon-cli skipped because a request they use failed its
-- checks, in order, from its `SKIP request "x": "y" failed its checks` lines.
local function skipped_from(stderr)
	local skipped = {}
	for line in (stderr or ""):gmatch("[^\n]+") do
		local label, reason = line:match('^SKIP request "(.-)": (.*)$')
		if label then
			table.insert(skipped, { label = label, reason = reason })
		end
	end
	return skipped
end

-- The `{"error": "..."}` summary axon-cli prints on stderr when checks failed.
local function summary_from(stderr)
	for line in vim.gsplit(stderr or "", "\n", { plain = true }) do
		if line:sub(1, 1) == "{" then
			local ok, decoded = pcall(vim.json.decode, line)
			if ok and type(decoded) == "table" and type(decoded.error) == "string" then
				return decoded.error
			end
		end
	end
end

-- Turns the `--with-deps` output (every response in the order sent; a looping
-- request is one slot holding its iterations; a skipped request is `null`)
-- into a flat list of entries. Returns the entries and, when exactly one
-- non-looping request was selected, the position of its entry.
local function flatten(decoded, requests, skipped)
	local by_index, selectors = {}, {}
	for _, request in ipairs(requests) do
		by_index[request.index] = request
		selectors[request.selector] = true
	end
	local function name_of(response)
		local request = by_index[response.index]
		if request and not response.dependency then
			return display_name(request)
		end
		return response.name or ("#" .. tostring(response.index))
	end

	local entries, selected, looped, next_skip = {}, {}, false, 1
	for _, slot in ipairs(vim.islist(decoded) and decoded or { decoded }) do
		if slot == vim.NIL then
			local skip = skipped[next_skip] or { label = "?", reason = "skipped" }
			next_skip = next_skip + 1
			table.insert(entries, {
				skipped = true,
				name = skip.label,
				label = skip.label,
				reason = skip.reason,
				dependency = not selectors[skip.label] or nil,
			})
			if selectors[skip.label] then
				table.insert(selected, #entries)
			end
		elseif vim.islist(slot) then
			looped = true
			for i, iteration in ipairs(slot) do
				iteration.name = string.format("%s [%d]", name_of(iteration), i - 1)
				iteration.element = i - 1
				table.insert(entries, iteration)
			end
		else
			slot.name = name_of(slot)
			table.insert(entries, slot)
			if not slot.dependency then
				table.insert(selected, #entries)
			end
		end
	end
	local target = (#requests == 1 and not looped) and selected[1] or nil
	return entries, target
end

local function cleanup(tmp)
	if tmp then
		os.remove(tmp)
	end
end

-- Runs `requests` from `file`, a snapshot of buffer `bufnr` in which
-- `listing` is every request (used to place check diagnostics).
local function execute(bufnr, file, requests, listing, tmp)
	local cfg = M.config
	local display = #requests == 1 and display_name(requests[1]) or string.format("all %d requests", #requests)
	local cmd = { vim.fn.expand(cfg.cmd), "-f", file }
	for _, request in ipairs(requests) do
		vim.list_extend(cmd, { "-n", request.selector })
	end
	-- --with-deps also prints the requests that ran only because a selected
	-- one references their response, so the whole chain can be shown.
	vim.list_extend(cmd, { "--json", "--with-deps" })
	if cfg.strict then
		table.insert(cmd, "--strict")
	end
	for _, arg in ipairs(cfg.args) do
		table.insert(cmd, (vim.fn.expand(arg)))
	end

	if vim.fn.executable(cmd[1]) ~= 1 then
		cleanup(tmp)
		ui.error(display, "axon-cli not found: " .. cmd[1] .. "\nSet `cmd` in require('axon').setup({ ... })", cfg)
		return
	end

	checks.clear(bufnr)
	ui.pending(display, cfg)
	local started = vim.uv.hrtime()
	vim.system(
		cmd,
		{ text = true },
		vim.schedule_wrap(function(result)
			cleanup(tmp)
			-- Keep `null` in arrays (vim.NIL): it marks a skipped request.
			local json_opts = { luanil = { object = true, array = false } }
			local ok, decoded = pcall(vim.json.decode, result.stdout or "", json_opts)
			if not ok or type(decoded) ~= "table" then
				-- Failures are reported as {"error": "..."} on stderr.
				ok, decoded = pcall(vim.json.decode, result.stderr or "", json_opts)
			end
			if not ok or type(decoded) ~= "table" then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				ui.error(display, msg ~= "" and msg or ("axon-cli exited with code " .. result.code), cfg)
				return
			end
			if decoded.error then
				ui.error(display, decoded.error, cfg)
				return
			end

			local elapsed = math.floor((vim.uv.hrtime() - started) / 1e6)
			local entries, target = flatten(decoded, requests, skipped_from(result.stderr))
			-- Set when checks failed or requests were skipped.
			local summary = result.code ~= 0 and summary_from(result.stderr) or nil
			if cfg.diagnostics then
				checks.report(bufnr, entries, listing)
			end
			if #entries == 0 then
				ui.info(display, "Nothing was sent: the @foreach array is empty.", cfg)
			elseif #entries == 1 and target then
				entries[1].duration_ms = elapsed
				ui.show(entries[1], cfg)
			else
				-- With one selected request (and its dependencies), open its
				-- response right away; <BS> goes to the whole chain.
				ui.show_all(entries, elapsed, cfg, target, summary)
			end
		end)
	)
end

-- Lists the buffer's requests; on success also returns the file they were
-- listed from and the temp file to remove afterwards, if any.
local function buffer_requests(bufnr)
	local file, tmp = source_file(bufnr)
	local requests, err = parser.requests(file)
	if requests and #requests == 0 then
		requests, err = nil, "no requests in this buffer"
	end
	if not requests then
		cleanup(tmp)
		vim.notify("axon: " .. err, vim.log.levels.WARN)
		return nil
	end
	return requests, file, tmp
end

-- `file` is the snapshot `listing` was made from, so the request's index matches.
local function run_request(bufnr, request, file, listing, tmp)
	-- Remember the real buffer so a rerun picks up later edits.
	last = { bufnr = bufnr, request = request }
	execute(bufnr, file, { request }, listing, tmp)
end

function M.run()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local listing, file, tmp = buffer_requests(bufnr)
	if not listing then
		return
	end
	for _, request in ipairs(listing) do
		if row >= request.start_row and row <= request.end_row then
			run_request(bufnr, request, file, listing, tmp)
			return
		end
	end
	cleanup(tmp)
	vim.notify("axon: no request under the cursor", vim.log.levels.WARN)
end

function M.pick()
	local bufnr = vim.api.nvim_get_current_buf()
	local requests, file, tmp = buffer_requests(bufnr)
	if not requests then
		return
	end
	vim.ui.select(requests, {
		prompt = "Axon request",
		format_item = function(request)
			return string.format("%s  %s %s", display_name(request), request.method, request.url)
		end,
	}, function(request)
		if request then
			run_request(bufnr, request, file, requests, tmp)
		else
			cleanup(tmp)
		end
	end)
end

function M.run_all()
	local bufnr = vim.api.nvim_get_current_buf()
	local requests, file, tmp = buffer_requests(bufnr)
	if not requests then
		return
	end
	last = { bufnr = bufnr, all = true }
	execute(bufnr, file, requests, requests, tmp)
end

function M.rerun()
	if not last then
		vim.notify("axon: no request has been run yet", vim.log.levels.WARN)
		return
	end
	if not vim.api.nvim_buf_is_valid(last.bufnr) then
		vim.notify("axon: the buffer of the last request is gone", vim.log.levels.WARN)
		return
	end
	local listing, file, tmp = buffer_requests(last.bufnr)
	if not listing then
		return
	end
	if last.all then
		execute(last.bufnr, file, listing, listing, tmp)
		return
	end
	-- Find the request again so edits that moved it are picked up.
	for _, request in ipairs(listing) do
		if request.selector == last.request.selector then
			last.request = request
			execute(last.bufnr, file, { request }, listing, tmp)
			return
		end
	end
	cleanup(tmp)
	vim.notify("axon: request " .. last.request.selector .. " is no longer in the buffer", vim.log.levels.WARN)
end

return M
