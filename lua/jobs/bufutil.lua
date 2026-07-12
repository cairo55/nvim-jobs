-- PRELUDE --
local fn = vim.fn
local api = vim.api

-- BUFFER UTILITY --
--- @param name string
--- @return integer
local function new(name)
  vim.validate('name', name, 'string')

  local new = api.nvim_create_buf(true, true)
  vim.bo[new].modifiable = false
  api.nvim_buf_set_name(new, name)
  return new
end

--- @param bufnr integer
--- @param cb    fun()
local function modify(bufnr, cb)
  vim.validate({
    bufnr = { bufnr, 'number' },
    cb = { cb, 'function' },
  })

  if not api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.bo[bufnr].modifiable = true
  cb()
  vim.bo[bufnr].modifiable = false
end

--- @param bufnr integer
--- @param lines string[]
local function append(bufnr, lines)
  vim.validate({
    bufnr = { bufnr, 'number' },
    lines = { lines, 'table' },
  })

  if #lines == 0 then
    return
  end
  modify(bufnr, function()
    -- FIXME: ugly workaround
    -- We want to set "one past the last line." New buffers spawn with one
    -- empty line. Hence, we end up with an empty line at the top of the
    -- buffer. To fix this, we explicitly check if there's only one line,
    -- and if it's empty , we simply overwrite it
    local lc = api.nvim_buf_line_count(bufnr)
    local empty = api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] == ''
    if lc == 1 and empty then
      api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    else
      api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    end
  end)
end

--- @param bufnr integer
local function clear(bufnr)
  vim.validate({
    bufnr = { bufnr, 'number' },
  })

  modify(bufnr, function()
    api.nvim_buf_set_lines(bufnr, 0, -1, true, {})
  end)
end

-- `bufnr` reimplementation, because the vim function tries to match a
-- `file-pattern` (according to `:help bufnr()`), but we want a literal match
--
--- @param name string
--- @return integer
local function nr(name)
  vim.validate({
    name = { name, 'string' },
  })

  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    -- XXX: `vim.api.nvim_get_buf_name` returns the bufname concatenated to
    -- the cwd for some fucking reason !!!!!!!! that's why this code
    -- doesn't use it.
    if name == fn.bufname(bufnr) then
      return bufnr
    end
  end
  return 0
end

--- @param bufnr integer
local function delete(bufnr)
  vim.validate({
    bufnr = { bufnr, 'number' },
  })
  api.nvim_buf_delete(bufnr, { force = true })
end

--- @param new integer?
local function current(new)
  vim.validate({
    new = { new, 'number', true },
  })

  local old = api.nvim_get_current_buf()
  if new and new ~= old then
    api.nvim_set_current_buf(new)
  end
  return old
end

--- @param bufnr integer
--- @param new   string
local function name(bufnr, new)
  vim.validate({
    bufnr = { bufnr, 'number' },
    new = { new, 'string' },
  })

  local old = fn.bufname()
  -- With `nomodifiable`, setting the buffer name to the same as it currently
  -- is seems to unset the alternate buffer for some reason. So don't do that.
  if new and new ~= old then
    api.nvim_buf_set_name(bufnr, new)
  end
  return old
end

--- @param bufnr integer
--- @return boolean
local function loaded_p(bufnr)
  vim.validate({
    bufnr = { bufnr, 'number' },
  })

  -- 0 refers to "current buffer" which isn't useful to me
  if bufnr == nil or bufnr == 0 then
    return false
  end
  return api.nvim_buf_is_loaded(bufnr)
end

--- @param bufnr integer
--- @return boolean
local function valid_p(bufnr)
  vim.validate({
    bufnr = { bufnr, 'number' },
  })

  -- 0 refers to "current buffer" which isn't useful to me
  if bufnr == nil or bufnr == 0 then
    return false
  end
  return api.nvim_buf_is_valid(bufnr)
end

--- @param bufnr  integer
--- @param row    integer
--- @param column integer?
--- @return boolean
local function posvalid_p(bufnr, row, column)
  vim.validate({
    bufnr = { bufnr, 'number' },
    row = { row, 'number' },
    column = { column, 'number', true },
  })

  local lc = vim.api.nvim_buf_line_count(bufnr)
  if row < 1 or row > lc then
    return false
  end
  if not column then
    return true
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1]
  return column >= 0 and column <= #line
end

--- @param bufnr integer
local function visible_p(bufnr)
  local wins = api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(wins) do
    if api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

--- @param bufnr integer
--- @param pos   [integer, integer]
local function set_cursor(bufnr, pos)
  local wins = fn.win_findbuf(bufnr)
  for _, win in ipairs(wins) do
    api.nvim_win_set_cursor(win, pos)
  end
end

return {
  new = new,
  modify = modify,
  append = append,
  clear = clear,
  nr = nr,
  delete = delete,
  current = current,
  name = name,
  loaded_p = loaded_p,
  valid_p = valid_p,
  posvalid_p = posvalid_p,
  visible_p = visible_p,
  set_cursor = set_cursor,
}
