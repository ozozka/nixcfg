return {
  runtime = { version = "LuaJIT", requirePattern = { "lua/?.lua", "lua/?/init.lua" } },
  diagnostics = { globals = { "vim" } },
  workspace = { library = { "$VIMRUNTIME" } },
}
