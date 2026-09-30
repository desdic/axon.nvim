-- Renders axon-cli responses into a reusable response buffer.
local M = {}

local BUF_NAME = "axon://response"

local ns = vim.api.nvim_create_namespace("axon")

local state = {
	bufnr = nil,
	responses = {}, -- decoded responses of the last run
	summary = false, -- whether the last run had several requests
	current = nil, -- index into `responses` being shown; nil for the summary
	summary_row = 1, -- cursor row to restore when going back to the summary
	total_ms = nil,
	view = "body", -- "body" | "headers"
}

local filetypes = {
	["application/json"] = "json",
	["application/xml"] = "xml",
	["text/xml"] = "xml",
	["text/html"] = "html",
	["application/javascript"] = "javascript",
	["text/javascript"] = "javascript",
	["text/css"] = "css",
	["text/plain"] = "text",
}

local function header(response, name)
	local values = response.headers and response.headers[name]
	return values and values[1]
end

local function filetype_for(response)
	local content_type = header(response, "content-type")
	if not content_type then
		return "text"
	end
	local mime = content_type:match("^[^;]+"):lower()
	if filetypes[mime] then
		return filetypes[mime]
	end
	if mime:match("%+json$") then
		return "json"
	end
	if mime:match("%+xml$") then
		return "xml"
	end
	return "text"
end

local function format_json(body, jq)
	if jq and vim.fn.executable(jq) == 1 then
		local result = vim.system({ jq, "." }, { stdin = body, text = true }):wait()
		if result.code == 0 then
			return result.stdout
		end
	end
	local ok, decoded = pcall(vim.json.decode, body)
	if ok then
		return vim.json.encode(decoded, { indent = "  " })
	end
	return body
end

local function body_lines(response, opts)
	local body = response.body or ""
	if opts.format_json and filetype_for(response) == "json" and body ~= "" then
		body = format_json(body, opts.jq)
	end
	return vim.split(body, "\n", { plain = true, trimempty = false })
end

local function header_lines(response)
	local lines = {
		string.format("%s %d %s", response.version or "HTTP", response.status.code, response.status.reason or ""),
	}
	local names = vim.tbl_keys(response.headers or {})
	table.sort(names)
	for _, name in ipairs(names) do
		for _, value in ipairs(response.headers[name]) do
			table.insert(lines, name .. ": " .. value)
		end
	end
	if response.cookies and #response.cookies > 0 then
		table.insert(lines, "")
		table.insert(lines, "# cookies")
		for _, cookie in ipairs(response.cookies) do
			table.insert(lines, type(cookie) == "string" and cookie or vim.json.encode(cookie))
		end
	end
	return lines
end

local function status_hl(code)
	if code >= 500 then
		return "DiagnosticError"
	elseif code >= 400 then
		return "DiagnosticWarn"
	elseif code >= 300 then
		return "DiagnosticInfo"
	end
	return "DiagnosticOk"
end

local function escape(s)
	return (s:gsub("%%", "%%%%"))
end

local function set_winbar(text)
	if not state.bufnr then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(state.bufnr)) do
		vim.wo[win].winbar = text
	end
end

local function ensure_buffer(opts)
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, BUF_NAME)
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false

	local map = function(lhs, rhs, desc)
		if lhs then
			vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, desc = desc })
		end
	end
	map(opts.keymaps.toggle_headers, M.toggle_view, "axon: toggle headers/body")
	map(opts.keymaps.rerun, function()
		require("axon").rerun()
	end, "axon: rerun last request")
	map(opts.keymaps.close, "<cmd>close<cr>", "axon: close response window")
	map(opts.keymaps.open, M.open_under_cursor, "axon: open response under cursor")
	map(opts.keymaps.back, M.back, "axon: back to the summary")

	state.bufnr = bufnr
	return bufnr
end

-- Shows the response buffer in a window, reusing one if it is already visible.
local function ensure_window(bufnr, opts)
	local win = vim.fn.win_findbuf(bufnr)[1]
	if win then
		return win
	end
	local current = vim.api.nvim_get_current_win()
	vim.cmd(opts.split)
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, bufnr)
	vim.wo[win].wrap = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.api.nvim_set_current_win(current)
	return win
end

local function set_lines(bufnr, lines, filetype)
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].modified = false
	if vim.bo[bufnr].filetype ~= filetype then
		vim.bo[bufnr].filetype = filetype
	end
end

local function set_cursor(row)
	for _, win in ipairs(vim.fn.win_findbuf(state.bufnr)) do
		local max = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(win, { math.min(row, max), 0 })
	end
end

local function hint(key, text)
	return key and string.format(" · %s %s", key, text) or ""
end

local function render_summary(opts)
	local bufnr = state.bufnr
	local width = 0
	for _, response in ipairs(state.responses) do
		width = math.max(width, vim.fn.strdisplaywidth(response.name or ""))
	end

	local lines, marks = {}, {}
	for i, response in ipairs(state.responses) do
		local status = string.format("%d %s", response.status.code, response.status.reason or "")
		local name = response.name or ""
		local line = string.format(
			"%2d  %-22s  %s%s  %s",
			i,
			status,
			name,
			string.rep(" ", width - vim.fn.strdisplaywidth(name)),
			response.url or ""
		)
		table.insert(lines, line)
		table.insert(marks, { row = i - 1, col = 4, end_col = 4 + #status, hl = status_hl(response.status.code) })
	end
	set_lines(bufnr, lines, "axon")

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	for _, mark in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
	end

	local failed = 0
	for _, response in ipairs(state.responses) do
		if response.status.code >= 400 then
			failed = failed + 1
		end
	end
	set_winbar(
		string.format(
			" %s%d requests%s%%*%%#Comment#%s%s%%*",
			failed > 0 and "%#DiagnosticWarn#" or "%#DiagnosticOk#",
			#state.responses,
			failed > 0 and string.format(", %d 4xx/5xx", failed) or "",
			state.total_ms and string.format(" · %d ms", state.total_ms) or "",
			hint(opts.keymaps.open, "to open")
		)
	)
	set_cursor(state.summary_row)
end

local function render_response(response, opts)
	local bufnr = state.bufnr
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	if state.view == "headers" then
		set_lines(bufnr, header_lines(response), "http")
	else
		set_lines(bufnr, body_lines(response, opts), filetype_for(response))
	end

	local position = state.summary and string.format("%d/%d  ", state.current, #state.responses) or ""
	local code = response.status.code
	set_winbar(
		string.format(
			"%%#%s# %d %s %%*  %s%s  %%#Comment#%s%s · [%s]%s%s%%*",
			status_hl(code),
			code,
			escape(response.status.reason or ""),
			position,
			escape(response.name or ""),
			escape(response.url or ""),
			response.duration_ms and string.format(" · %d ms", response.duration_ms) or "",
			state.view,
			hint(opts.keymaps.toggle_headers, "to toggle"),
			state.summary and hint(opts.keymaps.back, "for all") or ""
		)
	)
	set_cursor(1)
end

local function render(opts)
	if not state.bufnr or #state.responses == 0 then
		return
	end
	if state.summary and not state.current then
		render_summary(opts)
	else
		render_response(state.responses[state.current or 1], opts)
	end
end

local config

local function prepare(opts)
	config = opts
	local bufnr = ensure_buffer(opts)
	ensure_window(bufnr, opts)
	return bufnr
end

--- Shows a "running" placeholder while a request is in flight.
function M.pending(name, opts)
	prepare(opts)
	set_winbar(string.format("%%#Comment# running %s …%%*", escape(name)))
end

--- Displays a single decoded axon-cli response.
function M.show(response, opts)
	prepare(opts)
	state.responses, state.summary, state.current, state.total_ms = { response }, false, 1, nil
	render(opts)
end

--- Displays the responses of several requests as a summary list.
function M.show_all(responses, total_ms, opts)
	prepare(opts)
	state.responses, state.summary, state.current, state.total_ms = responses, true, nil, total_ms
	state.summary_row = 1
	render(opts)
end

--- Displays an error in the response buffer.
function M.error(name, message, opts)
	local bufnr = prepare(opts)
	state.responses, state.summary, state.current = {}, false, nil
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	set_lines(bufnr, vim.split(message, "\n", { plain = true }), "text")
	set_winbar(string.format("%%#DiagnosticError# error %%*  %s", escape(name or "")))
end

--- Switches between the body and the status line/headers view.
function M.toggle_view()
	state.view = state.view == "body" and "headers" or "body"
	if not (state.summary and not state.current) then
		render(config)
	end
end

function M.open_under_cursor()
	if not state.summary or state.current then
		return
	end
	local row = vim.api.nvim_win_get_cursor(0)[1]
	if state.responses[row] then
		state.summary_row = row
		state.current = row
		render(config)
	end
end

function M.back()
	if state.summary and state.current then
		state.current = nil
		render(config)
	end
end

return M
