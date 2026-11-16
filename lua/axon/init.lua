local parser = require("axon.parser")
local ui = require("axon.ui")

local M = {}

M.cli_version = "0.3"

local defaults = {
	cmd = "axon-cli",
	args = {},
	split = "botright vsplit", -- command used to open the response window
	format_json = true,
	jq = "jq",
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

-- Turns the `--with-deps` output (every response in the order sent; a looping
-- request is one slot holding its iterations) into a flat list of entries.
-- Returns the entries and, when exactly one non-looping request was selected,
-- the position of its response.
local function flatten(decoded, requests)
	local by_index = {}
	for _, request in ipairs(requests) do
		by_index[request.index] = request
	end
	local function name_of(response)
		local request = by_index[response.index]
		if request and not response.dependency then
			return display_name(request)
		end
		return response.name or ("#" .. tostring(response.index))
	end

	local entries, selected, looped = {}, {}, false
	for _, slot in ipairs(vim.islist(decoded) and decoded or { decoded }) do
		if vim.islist(slot) then
			looped = true
			for i, iteration in ipairs(slot) do
				iteration.name = string.format("%s [%d]", name_of(iteration), i - 1)
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

local function execute(file, requests, tmp)
	local cfg = M.config
	local display = #requests == 1 and display_name(requests[1]) or string.format("all %d requests", #requests)
	local cmd = { vim.fn.expand(cfg.cmd), "-f", file }
	for _, request in ipairs(requests) do
		vim.list_extend(cmd, { "-n", request.selector })
	end
	-- --with-deps also prints the requests that ran only because a selected
	-- one references their response, so the whole chain can be shown.
	vim.list_extend(cmd, { "--json", "--with-deps" })
	for _, arg in ipairs(cfg.args) do
		table.insert(cmd, (vim.fn.expand(arg)))
	end

	if vim.fn.executable(cmd[1]) ~= 1 then
		ui.error(display, "axon-cli not found: " .. cmd[1] .. "\nSet `cmd` in require('axon').setup({ ... })", cfg)
		return
	end

	ui.pending(display, cfg)
	local started = vim.uv.hrtime()
	vim.system(
		cmd,
		{ text = true },
		vim.schedule_wrap(function(result)
			cleanup(tmp)
			local json_opts = { luanil = { object = true, array = true } }
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
			local entries, target = flatten(decoded, requests)
			if #entries == 0 then
				ui.info(display, "Nothing was sent: the @foreach array is empty.", cfg)
			elseif #entries == 1 and target then
				entries[1].duration_ms = elapsed
				ui.show(entries[1], cfg)
			else
				-- With one selected request (and its dependencies), open its
				-- response right away; <BS> goes to the whole chain.
				ui.show_all(entries, elapsed, cfg, target)
			end
		end)
	)
end

-- `file` is the snapshot the request was listed from, so its index matches.
local function run_request(bufnr, request, file, tmp)
	-- Remember the real buffer so a rerun picks up later edits.
	last = { bufnr = bufnr, request = request }
	execute(file, { request }, tmp)
end

function M.run()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local file, tmp = source_file(bufnr)
	local request, err = parser.request_at(file, row)
	if not request then
		cleanup(tmp)
		vim.notify("axon: " .. err, vim.log.levels.WARN)
		return
	end
	run_request(bufnr, request, file, tmp)
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
			run_request(bufnr, request, file, tmp)
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
	execute(file, requests, tmp)
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
	if last.all then
		local requests, file, tmp = buffer_requests(last.bufnr)
		if requests then
			execute(file, requests, tmp)
		end
		return
	end
	local file, tmp = source_file(last.bufnr)
	execute(file, { last.request }, tmp)
end

return M
