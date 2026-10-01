-- Finds the requests in a .http file by asking axon-cli, so the plugin sees
-- exactly the requests the CLI will run.
local M = {}

---@class axon.Request
---@field selector string what to pass to `-n`: the name, or `#<index>` if unnamed
---@field name string|nil
---@field index integer 1-based
---@field method string
---@field url string
---@field start_row integer 0-based first row of the request's `###` block
---@field end_row integer 0-based last row of the block

--- Returns all requests in `file`, in file order.
---@param file string
---@return axon.Request[]|nil
---@return string|nil err
function M.requests(file)
	local axon = require("axon")
	local cmd = vim.fn.expand(axon.config.cmd)
	if vim.fn.executable(cmd) ~= 1 then
		return nil, "axon-cli not found: " .. cmd .. " (set `cmd` in require('axon').setup({ ... }))"
	end

	local result = vim.system({ cmd, "-f", file }, { text = true }):wait()
	local json_opts = { luanil = { object = true, array = true } }
	local ok, listing = pcall(vim.json.decode, result.stdout or "", json_opts)
	if result.code ~= 0 or not ok or not vim.islist(listing) then
		-- Failures are reported as {"error": "..."} on stderr.
		local eok, decoded = pcall(vim.json.decode, result.stderr or "", json_opts)
		local msg = eok and type(decoded) == "table" and decoded.error or vim.trim(result.stderr or "")
		return nil, msg ~= "" and msg or ("axon-cli exited with code " .. result.code)
	end

	local requests = {}
	for _, entry in ipairs(listing) do
		if not entry.start_line then
			return nil, "axon-cli is too old: its listing has no line ranges (update axon-cli)"
		end
		table.insert(requests, {
			selector = entry.name or ("#" .. entry.index),
			name = entry.name,
			index = entry.index,
			method = entry.method,
			url = entry.url,
			start_row = entry.start_line - 1,
			end_row = entry.end_line - 1,
		})
	end
	return requests
end

--- Returns the request whose block holds `row` (0-based), or nil and an error.
---@param file string
---@param row integer
---@return axon.Request|nil
---@return string|nil err
function M.request_at(file, row)
	local requests, err = M.requests(file)
	if not requests then
		return nil, err
	end
	for _, request in ipairs(requests) do
		if row >= request.start_row and row <= request.end_row then
			return request
		end
	end
	return nil, "no request under the cursor"
end

return M
