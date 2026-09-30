local parser = require("axon.parser")
local ui = require("axon.ui")

local M = {}

M.cli_version = "0.1"

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
	return request.label and (request.selector .. " " .. request.label) or request.selector
end

local function execute(file, requests, cleanup)
	local cfg = M.config
	local display = #requests == 1 and display_name(requests[1]) or string.format("all %d requests", #requests)
	local cmd = { vim.fn.expand(cfg.cmd), "-f", file }
	for _, request in ipairs(requests) do
		vim.list_extend(cmd, { "-n", request.selector })
	end
	table.insert(cmd, "--json")
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
			if cleanup then
				os.remove(cleanup)
			end
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
			-- Several -n flags produce an array, in the order given.
			local responses = vim.islist(decoded) and decoded or { decoded }
			for i, response in ipairs(responses) do
				if requests[i] then
					response.name = display_name(requests[i])
				end
			end
			if #responses == 1 then
				responses[1].duration_ms = elapsed
				ui.show(responses[1], cfg)
			else
				ui.show_all(responses, elapsed, cfg)
			end
		end)
	)
end

local function run_request(bufnr, request)
	local file, tmp = source_file(bufnr)
	-- Remember the real buffer so a rerun picks up later edits.
	last = { bufnr = bufnr, request = request }
	execute(file, { request }, tmp)
end

function M.run()
	local bufnr = vim.api.nvim_get_current_buf()
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local request, err = parser.request_at(bufnr, row)
	if not request then
		vim.notify("axon: " .. err, vim.log.levels.WARN)
		return
	end
	run_request(bufnr, request)
end

local function buffer_requests(bufnr)
	local requests, err = parser.requests(bufnr)
	if not requests then
		vim.notify("axon: " .. err, vim.log.levels.WARN)
		return nil
	end
	if #requests == 0 then
		vim.notify("axon: no requests in this buffer", vim.log.levels.WARN)
		return nil
	end
	return requests
end

function M.pick()
	local bufnr = vim.api.nvim_get_current_buf()
	local requests = buffer_requests(bufnr)
	if not requests then
		return
	end
	vim.ui.select(requests, {
		prompt = "Axon request",
		format_item = function(request)
			local target = request.method and (request.method .. " " .. request.url) or request.url
			return string.format("%s  %s", display_name(request), target)
		end,
	}, function(request)
		if request then
			run_request(bufnr, request)
		end
	end)
end

function M.run_all()
	local bufnr = vim.api.nvim_get_current_buf()
	local requests = buffer_requests(bufnr)
	if not requests then
		return
	end
	local file, tmp = source_file(bufnr)
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
	local requests = last.all and buffer_requests(last.bufnr) or { last.request }
	if not requests then
		return
	end
	local file, tmp = source_file(last.bufnr)
	execute(file, requests, tmp)
end

return M
