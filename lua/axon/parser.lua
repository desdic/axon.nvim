local M = {}

local function text(node, bufnr)
	return vim.trim(vim.treesitter.get_node_text(node, bufnr))
end

-- A trailing ` // comment` is not part of a name, as in axon-cli.
local function clean_name(name)
	return vim.trim((name:gsub("%s+//.*$", "")))
end

local function has_separator(section)
	local first = section:child(0)
	return first ~= nil and first:type() == "request_separator"
end

-- `# @name NAME` parses as a comment with an `identifier` and a `value` child.
local function name_override(comment, bufnr)
	local ident, value
	for child in comment:iter_children() do
		if child:type() == "identifier" then
			ident = text(child, bufnr)
		elseif child:type() == "value" then
			value = text(child, bufnr)
		end
	end
	if ident == "name" and value then
		return value
	end
end

-- Splits the document into requests: everything from one `###` up to the next.
local function groups(root)
	local result = {}
	local current
	for section in root:iter_children() do
		if section:type() == "section" then
			local start_row, _, end_row, end_col = section:range()
			-- A section ending at column 0 does not include its last row.
			if end_col == 0 then
				end_row = end_row - 1
			end
			if not current or has_separator(section) then
				current = { start_row = start_row, end_row = end_row, nodes = {} }
				table.insert(result, current)
			end
			current.end_row = math.max(current.end_row, end_row)
			for child in section:iter_children() do
				table.insert(current.nodes, child)
			end
		end
	end
	return result
end

-- The first plain comment above the request; JetBrains shows it as the label
-- of an unnamed request.
local function comment_label(comment, bufnr)
	if comment:child_count() > 0 then
		return nil -- `# @directive`
	end
	local label = text(comment, bufnr):gsub("^#+", ""):gsub("^//+", "")
	label = vim.trim(label)
	return label ~= "" and label or nil
end

-- Collects what we need to know about one `###` block.
local function describe(group, bufnr)
	local separator_name, override, request, label
	for _, child in ipairs(group.nodes) do
		local t = child:type()
		if t == "request_separator" then
			for v in child:iter_children() do
				if v:type() == "value" then
					separator_name = text(v, bufnr)
				end
			end
		elseif t == "comment" and not request then
			override = name_override(child, bufnr) or override
			label = label or comment_label(child, bufnr)
		elseif t == "request" then
			request = request or child
		end
	end
	local name = clean_name(override or separator_name or "")
	local named = name ~= ""
	return {
		name = named and name or nil,
		label = not named and label or nil,
		request = request,
		start_row = group.start_row,
		end_row = group.end_row,
	}
end

---@class axon.Request
---@field selector string what to pass to `-n`: the name, or `#<index>` if unnamed
---@field name string|nil
---@field label string|nil first comment of an unnamed request, as JetBrains shows it
---@field index integer 1-based, counting only blocks that hold a request
---@field method string|nil
---@field url string
---@field row integer 0-based row of the request line
---@field start_row integer
---@field end_row integer

-- Returns every `###` block, with `request` set only on those holding one.
local function blocks(bufnr)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "http")
	if not ok or not parser then
		return nil, "tree-sitter parser for `http` is not installed (:TSInstall http)"
	end
	local root = parser:parse()[1]:root()

	local result = {}
	local index = 0
	for _, group in ipairs(groups(root)) do
		local block = describe(group, bufnr)
		if block.request then
			index = index + 1
			block.index = index
			block.selector = block.name or ("#" .. index)
			for child in block.request:iter_children() do
				if child:type() == "method" then
					block.method = text(child, bufnr)
				elseif child:type() == "target_url" then
					block.url = text(child, bufnr)
				end
			end
			block.url = block.url or ""
			block.row = block.request:range()
			block.request = true
		end
		table.insert(result, block)
	end
	return result
end

--- Returns all requests in the buffer, in file order.
---@param bufnr integer
---@return axon.Request[]|nil
---@return string|nil err
function M.requests(bufnr)
	local all, err = blocks(bufnr)
	if not all then
		return nil, err
	end
	return vim.tbl_filter(function(block)
		return block.request ~= nil
	end, all)
end

--- Returns the request at `row` (0-based), or nil and an error.
---@param bufnr integer
---@param row integer
---@return axon.Request|nil
---@return string|nil err
function M.request_at(bufnr, row)
	local all, err = blocks(bufnr)
	if not all then
		return nil, err
	end
	for _, block in ipairs(all) do
		if row >= block.start_row and row <= block.end_row then
			if block.request then
				return block
			end
			break
		end
	end
	return nil, "no request under the cursor"
end

return M
