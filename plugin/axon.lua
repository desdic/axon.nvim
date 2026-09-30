if vim.g.loaded_axon then
	return
end
vim.g.loaded_axon = true

vim.api.nvim_create_user_command("AxonRun", function()
	require("axon").run()
end, { desc = "Run the HTTP request under the cursor with axon-cli" })

vim.api.nvim_create_user_command("AxonRunAll", function()
	require("axon").run_all()
end, { desc = "Run every HTTP request in the buffer with axon-cli" })

vim.api.nvim_create_user_command("AxonPick", function()
	require("axon").pick()
end, { desc = "Pick an HTTP request in the buffer and run it with axon-cli" })

vim.api.nvim_create_user_command("AxonRerun", function()
	require("axon").rerun()
end, { desc = "Run the last axon request again" })

vim.api.nvim_create_user_command("AxonToggleHeaders", function()
	require("axon.ui").toggle_view()
end, { desc = "Toggle the axon response between body and headers" })
