local v, api, opt, key, con = vim, vim.api, vim.opt, vim.keymap.set, table.concat

require("vim._core.ui2").enable {}

vim.cmd "colorscheme oz"

-- options
opt.cpoptions = "aABceFs_"
opt.autoread = true
opt.splitright = true
opt.shortmess = "aoOstTIcCF"
opt.whichwrap = "hlbs<>[]"
opt.clipboard = "unnamedplus"
opt.lazyredraw = true
-- opt.guicursor = 'a:block'
opt.mouse = "ar"
opt.mousefocus = true
opt.confirm = true
opt.breakindent = true
opt.ignorecase = true
opt.smartcase = true
opt.showmode = false
opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.cursorlineopt = "number"
opt.scrolloff = 3
opt.sidescrolloff = 12

-- tab
opt.smartindent = true
opt.shiftround = true
opt.expandtab = true
opt.tabstop = 2
opt.softtabstop = 2
opt.shiftwidth = 2

-- search
opt.inccommand = "split"

-- completion
opt.autocomplete = true
opt.pumheight = 6
opt.complete = { ".", "w", "b", "kspell", "i", "t", "f" } -- '.,w,b'
opt.completeopt = { "menu", "menuone", "noselect", "popup" } -- fuzzy.nosort
opt.wildoptions = { "pum", "tagfile", "fuzzy" }
opt.wildignorecase = true
opt.wildignore = "*.o,*.obj,*.exe,*.pdf"

local has_word = function ()
  local line, col = unpack(api.nvim_win_get_cursor(0))
  return col ~= 0
    and api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match "%s" == nil
end

key("i", "<Tab>", function ()
  if v.fn.pumvisible() == 1 then
    return "<C-n>"
  elseif has_word() then
    if v.bo.omnifunc ~= "" then
      return "<C-x><C-o>"
    else
      return "<C-n>"
    end
  else
    return "<Tab>"
  end
end, { expr = true, silent = true })

-- symbols
opt.list = true
opt.showbreak = "¬"
opt.listchars = { tab = "› ", trail = "🞄", nbsp = "␣" }
opt.fillchars = { eob = " ", fold = " ", lastline = " " }
-- opt.fillchars = { vert = ' ', vertleft = ' ', vertright = ' ', verthoriz = ' ', horiz = ' ', horizup = ' ', horizdown = ' ' }

opt.swapfile = false
opt.updatecount = 0
opt.shada = ""
opt.shadafile = ""
opt.backup = false
opt.undoreload = 0
opt.undofile = false

-- Spell
opt.spelllang = { "tr", "en_us", "en_gb" }
opt.spelloptions = { "camel" }
opt.spellsuggest = { "best", "6" }
opt.spellcapcheck = ""
opt.spell = false

-- fold
opt.foldmethod = "indent"
opt.foldlevelstart = 99
opt.foldtext = "v:lua.OzFold()"
function OzFold ()
  return con {
    api.nvim_buf_get_lines(0, v.v.foldstart - 1, v.v.foldstart, false)[1],
    " => ",
    v.v.foldend - v.v.foldstart + 1,
  }
end
