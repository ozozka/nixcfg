local con, v, api = table.concat, vim, vim.api
local col = function (color) return con { "%#", color, "#" } end

v.opt.laststatus = 3
v.opt.statusline = "%!v:lua.OzStatusline()"
api.nvim_create_autocmd({
  "WinEnter",
  "BufEnter",
  "BufWritePost",
  "LspAttach",
  "LspDetach",
  "DiagnosticChanged",
  "VimResized",
}, {
  callback = function () vim.cmd "redrawstatus" end,
})

local modes = {
  i = con { col "OzStatModeI", " I " },
  ic = con { col "OzStatModeI", " I " },
  v = con { col "OzStatModeV", " V " },
  V = con { col "OzStatModeV", " V " },
  ["\22"] = con { col "OzStatModeV", " V " },
  c = con { col "OzStatModeC", " C " },
  n = con { col "OzStatModeN", " N " },
}

local function get_buf_color (buf)
  return buf.hidden == 1 and (buf.changed == 1 and "OzBufHiddenChanged" or "OzBufHidden")
    or buf.changed == 1 and "OzBufChanged"
    or "OzBuf"
end

function OzStatusline ()
  local buffers = {}
  for i, b in ipairs(v.fn.getbufinfo { buflisted = 1 }) do
    buffers[i] = con {
      col "OzBuf",
      " ",
      b.bufnr,
      ":",
      col(get_buf_color(b)),
      v.fn.fnamemodify(b.name, ":p:."),
    }
  end

  local bufnr = api.nvim_get_current_buf()
  local diags = v.diagnostic.status(bufnr)
  if #v.lsp.get_clients { bufnr = bufnr } > 0 and diags == "" then
    diags = col "DiagnosticOk" .. "🞄"
  end

  return con {
    con(buffers),
    "%=%=",
    diags,
    " %*%L:%l-%{strdisplaywidth(getline('.'))}:%v",
    modes[api.nvim_get_mode().mode] or modes.n,
  }
end
