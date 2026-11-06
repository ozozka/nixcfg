local api, fn = vim.api, vim.fn

local keys = {
  del = "<del>",
  bs = "<bs>",
  cr = "<CR>",
  jl = "<c-g>U<left>",
  jr = "<c-g>U<right>",
  nest = "<C-o>O",
  undo = "<c-g>u",
}
local state = { bufs = {}, pats = {} }

local function is_in_table (table, val)
  if table == nil then return false end
  for _, cur in pairs(table) do
    if cur == val then return true end
  end
  return false
end

local function is_valid (is_table, not_table, val)
  return (is_table == nil or is_in_table(is_table, val))
    and (not_table == nil or not is_in_table(not_table, val))
end

local function can_do (conds, ...)
  if conds == nil then return true end
  for _, cond in pairs(conds) do
    if cond(...) == false then return false end
  end
  return true
end

local function count_char (text, char)
  local num = 0
  for i = 1, #text, 1 do
    if text:sub(i, i) == char then num = num + 1 end
  end
  return num
end

local Rule = setmetatable({}, {
  __call = function (self, headp, tailp, ft, not_ft)
    return setmetatable({
      pats = {},
      headp = headp,
      tailp = tailp,
      headp_len = api.nvim_strwidth(headp), --strdisplaywidth
      tailp_len = api.nvim_strwidth(tailp),
      ft = ft,
      not_ft = not_ft,
    }, { __index = self })
  end,
})

function Rule:Pat (name, key, conds, callback)
  self.pats[name] = setmetatable(
    { key = key, conds = conds, callback = callback },
    { __index = self }
  )
  return self
end

function Rule:add_cond (name, cond)
  table.insert(self.pats[name].conds, cond)
  return self
end

function Rule:exec (meta)
  meta.prevc = meta.line:sub(meta.col - meta.pat.headp_len + 1, meta.col)
  meta.nextc = meta.line:sub(meta.col + 1, meta.col + meta.pat.tailp_len)

  return can_do(self.conds, meta) and self.callback(meta) or nil
end

local function Pair (...)
  local rule = Rule(...)
  return rule
    :Pat("move", rule.tailp:match "[%z\1-\127\194-\244][\128-\191]*", {
      function (meta) return meta.key == meta.nextc and meta.key == meta.pat.tailp end,
    }, function (meta) return keys.jr:rep(meta.pat.tailp_len) end)
    :Pat(
      "del",
      keys.bs,
      {
        function (meta) return meta.pat.headp == meta.prevc and meta.pat.tailp == meta.nextc end,
      },
      function (meta) return keys.bs:rep(meta.pat.headp_len) .. keys.del:rep(meta.pat.tailp_len) end
    )
    :Pat(
      "pair",
      rule.headp:match "[^\128-\191][\128-\191]*$",
      {},
      function (meta) return meta.key .. meta.pat.tailp .. keys.jl:rep(meta.pat.tailp_len) end
    )
end

local function Quote (startp, ft, not_ft)
  return Pair(startp, startp, ft, not_ft):add_cond("pair", function (meta)
    if count_char(meta.line, meta.pat.headp) % 2 == 1 then return false end
  end)
end

local function Bracket (...)
  return Pair(...)
    :add_cond("move", function (meta)
      local balance = 0

      for i = 1, #meta.line, 1 do
        local c = meta.line:sub(i, i)
        if c == meta.pat.headp then
          balance = balance + 1
        elseif balance > 0 and c == meta.key then
          balance = balance - 1
          if meta.col <= i and balance == 0 then break end
        end
      end

      if balance ~= 0 then return false end
    end)
    :Pat("indent", keys.cr, {
      function (meta)
        if not (meta.pat.headp == meta.prevc and meta.pat.tailp == meta.nextc) then
          return false
        end
      end,
    }, function (_) return keys.cr .. keys.nest end)
    :add_cond("pair", function (meta)
      local balance = 0

      for i = 1, #meta.line, 1 do
        local c = meta.line:sub(i, i)
        if c == meta.pat.headp then
          balance = balance + 1
        elseif c == meta.pat.tailp then
          balance = balance - 1
          if balance < 0 then
            if i > meta.col then
              return false
            else
              balance = 0
            end
          end
        end
      end

      if balance < 0 then return false end
    end)
end

local function Endwise (...)
  return Rule(...):Pat("end", keys.cr, {
    function (meta)
      local end_text = meta.line:sub(meta.col + 1)

      if
        not meta.line:match(meta.pat.headp)
        or (end_text ~= "" and end_text:match "^%s+$" == nil)
      then
        return false
      end
    end,
  }, function (meta) return keys.cr .. meta.pat.tailp .. keys.nest end)
end

local Buf = setmetatable({}, {
  __call = function (self, bufnr, ft)
    if state.bufs[bufnr] then
      for key, _ in pairs(state.bufs[bufnr].pats) do
        pcall(api.nvim_buf_del_keymap, bufnr, "i", key)
      end
      state.bufs[bufnr] = nil
    end

    if not vim.treesitter.highlighter.active[bufnr] then return end

    local buf = setmetatable({ nr = bufnr, ft = ft, pats = {} }, { __index = self })
    state.bufs[buf.nr] = buf
    for _, pat in pairs(state.pats) do
      buf:add_map(pat)
    end
  end,
})

function Buf:add_map (pat)
  if not is_valid(pat.ft, pat.no_ft, self.ft) then return end

  if not self.pats[pat.key] then
    self.pats[pat.key] = {}
    api.nvim_buf_set_keymap(self.nr, "i", pat.key, "", {
      expr = true,
      noremap = true,
      callback = function ()
        local res = self:map_exec(pat.key)
        res = (res and keys.undo .. res .. keys.undo) or pat.key
        return api.nvim_replace_termcodes(res, true, false, true)
      end,
    })
  end

  table.insert(self.pats[pat.key], pat)
end

function Buf:map_exec (key)
  if
    fn.reg_recording() ~= ""
    or fn.reg_executing() ~= ""
    or fn.visualmode() == "^V"
    or vim.v.count > 0
  then
    return
  end

  local col = api.nvim_win_get_cursor(0)[2]
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local line = api.nvim_buf_get_lines(self.nr, row, row + 1, false)[1] or ""
  local meta = {
    key = key,
    buf = self,
    col = col,
    row = row,
    line = line,
    line_prev = line:sub(1, col),
    line_next = line:sub(col + 1, #line),
    char_prev = line:sub(col, col),
    char_next = line:sub(col + 1, col + 1),
  }

  for _, pat in pairs(self.pats[key]) do
    meta.pat = pat
    local res = pat:exec(meta)
    if res then return res end
  end
end

local rules = {
  Bracket("(", ")"),
  Bracket("[", "]"),
  Bracket("{", "}"),
  Bracket("<", ">", { "html", "xml", "javascriptreact", "typescriptreact" }),

  Quote "'",
  Quote "`",
  Quote "\"",

  Endwise(".-then *$", "end", { "lua" }),
  Endwise(".-do *$", "end", { "lua" }),
  Endwise(".-function.-%(.-%) *$", "end", { "lua" }),
}

for _, rule in ipairs(rules) do
  for _, pat in pairs(rule.pats) do
    state.pats[#state.pats + 1] = pat
  end
end

table.sort(
  state.pats,
  function (a, b)
    return (
      a.headp == b.headp
      and (((not b.key) and a.key) or ((not a.key) and b.key) or (#a.key < #b.key))
    )
      or (
        (a.headp_len == b.headp_len and a.headp:byte() > b.headp:byte())
        or a.headp_len > b.headp_len
      )
  end
)

api.nvim_create_autocmd("FileType", {
  callback = function (param) Buf(param.buf, param.match) end,
})
