-- PRELUDE --
local fn = vim.fn
local api = vim.api

local jobc = require('jobs/control')
local bufu = require('jobs/bufutil')

-- STATE --
--- @class Keyword.Association
--- @field name string   Short and helpful identifier for the command
--- @field cmd  string[] The command
--- @field ft   string   Filetype to use for the opened buffer

--- @type table<string, Keyword.Association>
local assoc = {}

-- IMPLEMENTATION --
local function keyword(kw)
  local ft = vim.bo.filetype
  if not assoc[ft] then
    vim.notify('No handler for current filetype')
    return
  end

  local cmd = assoc[ft].cmd
  local name = assoc[ft].name

  local id = string.format('keyword %s %s', name, kw)
  local job = jobc.start(id, { unpack(cmd), kw }, {
    buf = {
      name = string.format('[%s %s]', name, kw),
      confcb = function(bufnr)
        if assoc[ft].ft then
          vim.bo[bufnr].filetype = assoc[ft].ft
        end
      end,
    },
  })
  if not job then
    return
  end

  local buf = job:buf()
  bufu.current(buf)
end

-- COMMANDS --
local function Keyword(opts)
  local mode = fn.mode()

  local selection
  if opts.args ~= '' then
    selection = opts.args
  elseif mode == 'n' or mode:sub(1, 2) == 'ni' then
    selection = fn.expand('<cword>')
  elseif mode == 'v' or mode == 'vs' then
    selection = fn.getregion(fn.getpos('.'), fn.getpos('v'))[1]
  else
    return
  end

  selection = selection:gsub('^%s*(.-)%s*$', '%1')
  if selection == '' then
    return
  end

  keyword(selection)
end

-- SETUP --
--- @param assocs? table<string, Keyword.Association>
local function setup(assocs)
  vim.validate('assocs', assocs, 'table', true)
  if assocs then
    for k in pairs(assoc) do
      assoc[k] = nil
    end
    for k in pairs(assocs) do
      assoc[k] = assocs[k]
    end
  end

  api.nvim_create_user_command('Keyword', Keyword, {
    nargs = '*',
    desc = 'Look up the current word in a help program',
  })
end

-- INTERFACE --
return {
  setup = setup,
  keyword = keyword,
  assoc = assoc,
}
