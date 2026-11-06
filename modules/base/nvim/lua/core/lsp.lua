local v, api, opt, key, con = vim, vim.api, vim.opt, vim.keymap.set, table.concat

v.lsp.enable {
  "bashls",
  "clangd",
  "cssls",
  "dockerls",
  "emmylua_ls",
  "eslint",
  "html",
  "jsonls",
  "just",
  "marksman",
  "nixd",
  "rust-analyzer",
  "sqls",
  "tinymist",
  "tsls",
  "ty",
  "yamlls",
}

v.diagnostic.config {
  update_in_insert = false,
  underline = true,
  signs = false,
  severity_sort = true,
  float = { source = "if_many" },
  virtual_text = {
    severity = { min = v.diagnostic.severity.WARN },
    spacing = 2,
    source = "if_many",
    prefix = "🞄",
  },
}

api.nvim_create_autocmd("LspAttach", {
  group = api.nvim_create_augroup("my.lsp", { clear = true }),
  callback = function (args)
    local client = v.lsp.get_client_by_id(args.data.client_id)
    if client == nil then return end

    if client:supports_method "textDocument/completion" then
      v.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end

    if client:supports_method "textDocument/foldingRange" then
      v.opt_local.foldmethod = "expr"
      v.opt_local.foldexpr = "v:lua.vim.lsp.foldexpr()"
    end

    api.nvim_buf_create_user_command(args.buf, "FormatBuf", function ()
      v.lsp.buf.format { bufnr = args.buf, id = client.id, timeout_ms = 1000 }
      print "Formatted"
    end, {}
    )

    -- if client:supports_method 'textDocument/formatting'
    --     and not client:supports_method 'textDocument/willSaveWaitUntil' then
    --   api.nvim_buf_create_user_command(args.buf, 'FormatBuf', function()
    --     v.lsp.buf.format { bufnr = args.buf, id = client.id, timeout_ms = 1000 }
    --     print("Formatted")
    --   end, {})
    -- end
  end,
})
