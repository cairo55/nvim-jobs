-- PRELUDE --
local fn = vim.fn
local api = vim.api
local loglvl = vim.log.levels

local bufu = require('jobs/bufutil')

-- TYPE DECLARATIONS --
--- @class Job.BufferOpts
--- @field name?     string
--- @field headercb? fun(): string[]
--- @field footercb? fun(exit: vim.SystemCompleted, output: string[]): string[]
--- @field confcb?   fun(bufnr: integer)

--- @class Job.Buffer
--- @field nr? integer

--- @class Job
--- @field id      string
--- @field nr      integer
--- @field cmd     string[]
--- @field header  string[]
--- @field footer  string[]
--- @field output  string[]
--- @field buf     Job.Buffer
--- @field bufopts Job.BufferOpts
--- @field obj?    vim.SystemObj
--- @field exit?   vim.SystemCompleted

--- @class Job.IdEntry
--- @field buf      Job.Buffer
--- @field current? Job
--- @field old      Job[]

--- @class Job.Table
--- @field [integer] Job
--- @field [string]  Job.IdEntry

--- @class Job.LineInfo
--- @field line string
--- @field lnum integer

--- @class Job.WriterCallbacks
--- @field filtercb? fun(lines: string[])
--- @field postcb?   fun(job: Job, lineinfo: Job.LineInfo[])

--- @class Job.Callbacks
--- @field out?    Job.WriterCallbacks
--- @field err?    Job.WriterCallbacks
--- @field exitcb? fun(job: Job)

--- @class Job.StartOpts
--- @field bufopts?   Job.BufferOpts
--- @field callbacks? Job.Callbacks

-- STATE --
--- @type Job.Table
local jobs = {}

-- AUGROUP --
local augroup = api.nvim_create_augroup('JobCtrl', { clear = true })

-- INPUT PROCESSING --
local function chunker(cb, ctx)
  local accum = ''
  return function(err, data)
    -- these two branches are untested >_<
    if not data then
      if accum ~= '' then
        cb({ accum }, ctx)
      end
      if not err then
        return
      end
    end
    if err then
      vim.notify('vim.system error: ' .. err, loglvl.ERROR)
      return
    end

    local lines = {}
    local start = 1
    while true do
      local nl = data:find('\n', start)
      if not nl then
        accum = accum .. data:sub(start)
        break
      end

      table.insert(lines, accum .. data:sub(start, nl - 1))
      accum = ''
      start = nl + 1
    end

    if #lines > 0 then
      cb(lines, ctx)
    end
  end
end

local function writer(lines, info)
  local job, cb = info.job, info.cb

  vim.schedule(function()
    if cb.filtercb then
      cb.filtercb(lines)
    end

    local buf = job.buf

    local lineinfo = {}
    for i = 1, #lines do
      local last = #job.output
      job.output[last + 1] = lines[i]
      table.insert(lineinfo, {
        line = lines[i],
        lnum = (job.header and #job.header or 0) + last + 1,
      })
    end

    if bufu.loaded_p(buf.nr) then
      bufu.append(buf.nr, lines)
    end

    if cb.postcb then
      cb.postcb(job, lineinfo)
    end
  end)
end

local function on_exit(exit, info)
  local job = info.job
  job.obj = nil
  job.exit = exit
  jobs[job.id].current = nil
  table.insert(jobs[job.id].old, job)
  vim.schedule(function()
    local bufopts = job.bufopts

    local msg
    local c = exit.code + exit.signal
    if c == 0 then
      msg = string.format('%s terminated successfully', job.id)
    else
      msg = string.format('%s failed with code %i', job.id, c)
    end
    vim.notify(msg, c == 0 and loglvl.INFO or loglvl.ERROR)

    if info.cb then
      info.cb(job)
    end

    if bufu.loaded_p(job.buf.nr) and bufopts.footercb then
      bufu.append(job.buf.nr, bufopts.footercb(exit, job.output))
    end
  end)
end

-- JOB INTERFACE --
--- @class Job
local Job = {}
Job.__index = Job

--- @param id   string
--- @param cmd  string[]
--- @param opts Job.StartOpts?
--- @return Job?
local function start(id, cmd, opts)
  vim.validate({
    id = { id, 'string' },
    cmd = { cmd, 'table' },
    opts = { opts, 'table', true },
  })
  assert(#cmd > 0)
  assert(#id > 0)

  opts = opts or {}

  if not jobs[id] then
    jobs[id] = {
      buf = {},
      current = nil,
      old = {},
    }
  end

  if jobs[id].current then
    return nil
  end

  local cb = opts.callbacks or {}

  local job = {}
  setmetatable(job, Job)

  job.id = id
  job.nr = #jobs + 1
  job.cmd = cmd
  job.output = {}
  job.buf = jobs[id].buf
  job.bufopts = opts.bufopts or {}

  local obj = vim.system(cmd, {
    detach = true,
    text = true,
    stdout = chunker(writer, { job = job, cb = cb.out or {} }),
    stderr = chunker(writer, { job = job, cb = cb.err or {} }),
  }, function(exit)
    on_exit(exit, { job = job, cb = cb.exitcb })
  end)

  job.obj = obj
  job.exit = nil

  jobs[id].current = job
  table.insert(jobs, job)

  return job
end

--- @param signal string?
--- @return 0?             success
--- @return string?        err
--- @return uv.error_name? err_name
function Job:kill(signal)
  vim.validate('signal', signal, 'string', true)
  if not self.obj then
    return 0
  end
  -- XXX: process needs to be a process group leader for this
  return vim.uv.kill(-self.obj.pid, signal or 'sigterm')
end

--- @param replace? boolean
--- @param delete? boolean
--- @return Job.Buffer
function Job:newbuf(replace, delete)
  vim.validate({
    replace = { replace, 'boolean', true },
    delete = { delete, 'boolean', true },
  })

  if replace == nil then
    replace = true
  end
  if delete == nil then
    delete = true
  end

  local bufopts = self.bufopts

  if not bufopts.name then
    bufopts.name = string.format('[Job %s]', self.id)
  end

  --- @type Job.Buffer
  local buf = { nr = bufu.new() }

  if replace then
    local old = self.buf
    if old.nr and bufu.valid_p(old.nr) then
      for _, win in ipairs(fn.win_findbuf(old.nr)) do
        if delete then
          local alt = fn.bufnr('#')
          if alt > 0 then
            api.nvim_win_set_buf(win, alt)
          end
        end
        api.nvim_win_set_buf(win, buf.nr)
      end
      if delete then
        bufu.delete(old.nr)
        old.nr = nil
      end
    end
  end

  -- buffer we don't own, but using the name we want
  local target = bufu.nr(bufopts.name)
  if target > 0 then
    bufu.delete(target)
  end

  bufu.name(buf.nr, bufopts.name)

  self:setbuf(buf)
  return buf
end

--- @param buf Job.Buffer
function Job:setbuf(buf)
  local bufopts = self.bufopts

  if not buf.nr or not bufu.loaded_p(buf.nr) then
    return
  end

  api.nvim_create_autocmd('BufDelete', {
    buffer = buf.nr,
    callback = function()
      if self.exit then
        return
      end
      vim.notify(string.format('%s will continue to run', self.id))
    end,
    once = true,
    group = augroup,
  })

  bufu.clear(buf.nr)

  if #self.header > 0 then
    bufu.append(buf.nr, self.header)
  end
  if #self.output > 0 then
    bufu.append(buf.nr, self.output)
  end
  if #self.footer > 0 then
    bufu.append(buf.nr, self.footer)
  end

  if bufopts.confcb then
    bufopts.confcb(buf.nr)
  end

  self.buf = buf
  jobs[self.id].buf = buf
end

--- @param nr_or_id integer | string
--- @return Job | Job.IdEntry
local function get(nr_or_id)
  vim.validate('nr_or_id', nr_or_id, { 'number', 'string' })

  local job = jobs[nr_or_id]
  if job and type(nr_or_id) == 'string' then
    return job.current or job.old[#job.old]
  end
  return job
end

--- @param id? string
local function last(id)
  vim.validate('id', id, 'string', true)
  if not id then
    return #jobs > 0 and jobs[#jobs] or nil
  end
  local job = jobs[id]
  if not job then
    return nil
  end
  if job.current then
    return job.current
  end
  if #job.old > 0 then
    return job.old[#job.old]
  end
  return nil
end

-- INTERFACE --
return {
  start = start,
  get = get,
  last = last,
  jobs = jobs,
}
