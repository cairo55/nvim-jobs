-- PRELUDE --
local fn = vim.fn
local api = vim.api

local o = vim.o
local bo = vim.bo

local bufu = require('jobs/bufutil')
local jobc = require('jobs/control')

local loglvl = vim.log.levels

-- COMMANDS --
local function JobStop_complete()
  local ret = {}
  for i = #jobc.jobs, 1, -1 do
    local job = jobc.jobs[i]
    if job.obj then
      table.insert(ret, job.id)
    end
  end
  return ret
end

local function JobBuffer_complete()
  local ret = {}
  local seen = {}
  for i = #jobc.jobs, 1, -1 do
    local job = jobc.jobs[i]
    if not seen[job.id] then
      table.insert(ret, job.id)
    end
    seen[job.id] = true
  end
  return ret
end

local function JobStop(opts)
  local id = opts.args

  local job
  if id == '' then
    for _, j in pairs(jobc.jobs) do
      if j.obj and j.buffer.nr == bufu.current() then
        job = j
      end
    end
    if not job then
      vim.notify('No job associated with current buffer', loglvl.ERROR)
      return
    end
  else
    job = jobc.get(id)
    if not job or not job.obj then
      vim.notify(string.format("No job with ID `%s'", id), loglvl.ERROR)
      return
    end
  end

  local _, err = job:kill()
  if err then
    vim.notify(err, loglvl.ERROR)
  end
end

local function JobBuffer(opts)
  local job = jobc.get(opts.args)
  if not job then
    vim.notify(string.format("No job with ID `%s'", opts.args), loglvl.ERROR)
    return
  end

  local buf = job:buf()
  bufu.current(buf)
end

local function setup()
  api.nvim_create_user_command('JobStop', JobStop, {
    desc = 'Stop job associated with current buffer, or by ID',
    nargs = '*',
    complete = JobStop_complete,
  })

  api.nvim_create_user_command('JobBuffer', JobBuffer, {
    desc = "Open job's output buffer",
    nargs = '*',
    complete = JobBuffer_complete,
  })

  local augroup = api.nvim_create_augroup('JobControl', { clear = true })
  api.nvim_create_autocmd('VimLeave', {
    desc = 'Reap running jobs on exit',
    callback = function()
      for _, job in ipairs(jobc.jobs) do
        if job.obj then
          job:kill()
        end
      end
    end,
    group = augroup,
  })
end

return {
  setup = setup,
}
