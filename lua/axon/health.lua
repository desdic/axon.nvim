-- :checkhealth axon
local M = {}

local health = vim.health

local function major_minor(output)
	local major, minor = output:match("(%d+)%.(%d+)")
	return major and (major .. "." .. minor) or nil
end

local function check_cli(axon)
	local cmd = vim.fn.expand(axon.config.cmd)
	if vim.fn.executable(cmd) ~= 1 then
		health.error("axon-cli not found: " .. cmd, {
			"Build it with `cargo build --release` in axon-cli",
			"Put it on $PATH or set `cmd` in require('axon').setup({ ... })",
		})
		return
	end
	health.ok("axon-cli found: " .. vim.fn.exepath(cmd))

	local ok, result = pcall(function()
		return vim.system({ cmd, "-V" }, { text = true }):wait(5000)
	end)
	if not ok or result.code ~= 0 then
		health.error("`" .. cmd .. " -V` failed: " .. vim.trim(ok and (result.stderr or "") or tostring(result)))
		return
	end

	local output = vim.trim(result.stdout or "")
	local found = major_minor(output)
	if not found then
		health.error("could not read a version from `" .. cmd .. " -V`: " .. output)
	elseif found ~= axon.cli_version then
		health.error(
			string.format(
				"axon-cli %s is not supported; axon.nvim needs %s.x",
				output:match("%d+%.%d+%S*"),
				axon.cli_version
			),
			{ "Update axon-cli or axon.nvim so their versions match" }
		)
	else
		health.ok(string.format("axon-cli version %s (needs %s.x)", output:match("%d+%.%d+%S*"), axon.cli_version))
	end
end

function M.check()
	local axon = require("axon")

	health.start("axon.nvim")
	if vim.fn.has("nvim-0.10") == 1 then
		local v = vim.version()
		health.ok(string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch))
	else
		health.error("Neovim 0.10 or newer is required")
	end

	if pcall(vim.treesitter.language.inspect, "http") then
		health.ok("tree-sitter parser for `http` is installed")
	else
		health.error("tree-sitter parser for `http` is not installed", { ":TSInstall http" })
	end

	health.start("axon-cli")
	check_cli(axon)

	health.start("optional")
	if not axon.config.format_json then
		health.info("JSON formatting is off (`format_json = false`)")
	elseif vim.fn.executable(axon.config.jq) == 1 then
		health.ok("jq found: JSON bodies are pretty-printed in their original key order")
	else
		health.warn("jq not found: JSON bodies are pretty-printed with vim.json, which sorts keys", { "Install jq" })
	end
end

return M
