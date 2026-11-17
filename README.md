<p align="center">
  <img src="images/axon_logo.jpeg" alt="axon.nvim logo" width="600">
</p>

# axon.nvim

Run requests from `.http` files in Neovim using [axon-cli](https://github.com/desdic/axon-cli).

## Requirements

- Neovim 0.12+
- `axon-cli` on `$PATH`, or set with `cmd`
- `jq` (optional), which pretty-prints JSON bodies without changing key order

Run `:checkhealth axon` to check all of these.

## Defaults

```lua
require("axon").setup({
  cmd = "axon-cli",           -- or an absolute path to axon-cli
  args = {},                  -- arguments for axon-cli
  split = "botright vsplit",  -- command to split window
  format_json = true,         -- format json
  jq = "jq",                  -- jq for formatting
  strict = false,             -- pass --strict: a failed @warn fails the run like @assert
  diagnostics = true,         -- show failed checks as diagnostics in the .http buffer
  keymaps = { toggle_headers = "H", rerun = "R", close = "q", open = "<CR>", back = "<BS>" }, -- false disables
})
```
## Setup

Example of lazy loading with Neovims vim.pack

```lua
vim.pack.add({
    { src = "https://github.com/desdic/axon.nvim", load = false },
}, { confirm = false })

vim.api.nvim_create_autocmd("FileType", {
    pattern = "http",
    callback = function(event)
        if not vim.g.axon_nvim_loaded then
            require("axon").setup({})
            vim.g.axon_nvim_loaded = true
        end

        local opts = { buffer = event.buf, remap = false }

        opts.desc = "Axon run request"
        vim.keymap.set("n", "<leader>As", "<cmd>AxonRun<cr>", opts)

        opts.desc = "Axon run all requests"
        vim.keymap.set("n", "<leader>Aa", "<cmd>AxonRunAll<cr>", opts)

        opts.desc = "Axon pick request"
        vim.keymap.set("n", "<leader>Ap", "<cmd>AxonPick<cr>", opts)

        opts.desc = "Axon toggle headers"
        vim.keymap.set("n", "<leader>At", "<cmd>AxonToggleHeaders<cr>", opts)

        opts.desc = "Axon rerun request"
        vim.keymap.set("n", "<leader>Ar", "<cmd>AxonRerun<cr>", opts)
    end,
})

```

## Commands

| Command | Description |
|---|---|
| `:AxonRun` | Run the request under the cursor |
| `:AxonRunAll` | Run every request in the buffer, in order, in one axon-cli call so cookies carry over |
| `:AxonPick` | Pick a request in the buffer from a list (`vim.ui.select`) and run it |
| `:AxonRerun` | Run the last request (or all of them, after `:AxonRunAll`) again, picking up any edits |
| `:AxonToggleHeaders` | Switch the response between body and status line + headers |

## Chained requests and loops

Requests that use another request's response (`{{login.response.body.$.token}}`) or loop over one (`# @foreach`) are run by axon-cli together with their dependencies, and the plugin shows the whole chain:

- `:AxonRun` on a request with dependencies opens its response directly; the winbar shows `2/2` and `<BS>` goes back to the list of every response sent, with dependencies dimmed and marked `dependency`. `<CR>` opens any of them, e.g. to see what `login` returned.
- A looping request shows one row per iteration (`details [0]`, `details [1]`, …).

## Checks

`# @assert`, `# @warn` and `# @notice` lines, and their inverted forms `# @fail-if`, `# @warn-if` and `# @notice-if` (see the [axon-cli README](https://github.com/desdic/axon-cli#checks)) are shown in three places:

- **The `.http` buffer**: each failed check is a diagnostic on its line (`@assert` an error, `@warn` a warning, `@notice` info), so it shows in the sign column and `]d`/`[d` jump between them. For a looping request, the message names the element (`[1] @notice …`). A request that was not sent because a request it uses failed an assert gets an info diagnostic on its `###` line. Each run replaces the previous run's diagnostics. Set `diagnostics = false` to turn this off.
- **The response window**: the winbar shows `✓ 3 checks` when everything passed, or the failures per level (`✗ 1 assert ⚠ 1 warn`). The failed checks are listed above the body, and the headers view (`H`) ends with a `# checks` section listing every check, passing ones included.
- **The summary list**: each row shows its check results; skipped requests are `SKIP` rows with the reason, and the winbar shows axon-cli's summary (`1 check failed, 1 request skipped`).

This needs axon-cli 0.5.1 or newer for the `-if` forms (it uses `--json --with-deps` and the `checks` field).
