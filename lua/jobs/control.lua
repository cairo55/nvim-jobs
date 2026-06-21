-- PRELUDE --
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
--- @field nr      integer
--- @field header? string[]
--- @field footer? string[]
--- @field opts    Job.BufferOpts

--- @class Job
--- @field id     string
--- @field nr     integer
--- @field cmd    string[]
--- @field output string[]
--- @field buffer Job.Buffer
--- @field obj?   vim.SystemObj
--- @field exit?  vim.SystemCompleted

--- @class Job.IdEntry
--- @field buffer   Job.Buffer
--- @field current? Job
--- @field old      Job[]

--- @class Job.Table
--- @field [integer] Job
--- @field [string]  Job.IdEntry

--- @class Job.LineInfo
--- @field line string
--- @field lnum integer

--- @class Job.WriterCallbacks
--- @field filter? fun(lines: string[])
--- @field post?   fun(job: Job, lineinfo: Job.LineInfo[])

--- @class Job.Callbacks
--- @field out?  Job.WriterCallbacks
--- @field err?  Job.WriterCallbacks
--- @field exit? fun(job: Job)

--- @class Job.StartOpts
--- @field buf? Job.BufferOpts
--- @field cb?  Job.Callbacks

-- STATE --
--- @type Job.Table
local jobs = {}

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
    if cb.filter then
      cb.filter(lines)
    end

    local buf = job.buffer

    local lineinfo = {}
    for i = 1, #lines do
      local last = #job.output
      job.output[last + 1] = lines[i]
      table.insert(lineinfo, {
        line = lines[i],
        lnum = (buf.header and #buf.header or 0) + last + 1,
      })
    end

    if bufu.loaded_p(buf.nr) then
      bufu.append(buf.nr, lines)
    end

    if cb.post then
      cb.post(job, lineinfo)
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
    local buf = job.buffer
    local opts = buf.opts

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

    if bufu.loaded_p(buf.nr) and opts.footercb then
      bufu.append(buf.nr, opts.footercb(exit, job.output))
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
      buffer = {
        nr = 0,
        opts = {},
      },
      current = nil,
      old = {},
    }
  end

  if jobs[id].current then
    return nil
  end

  local cb = opts.cb or {}

  local job = {}
  setmetatable(job, Job)

  job.id = id
  job.nr = #jobs + 1
  job.cmd = cmd
  job.output = {}
  job.buffer = jobs[id].buffer

  local buf = job.buffer
  local bufopts = opts.buf or buf.opts
  buf.opts = bufopts
  if bufu.loaded_p(buf.nr) then
    bufu.clear(buf.nr)
    if bufopts.headercb then
      buf.header = bufopts.headercb()
      bufu.append(buf.nr, buf.header)
    end
  end

  -- TODO: make this not use `setpgid`
  local obj = vim.system(cmd, {
    detach = true,
    text = true,
    stdout = chunker(writer, { job = job, cb = cb.out or {} }),
    stderr = chunker(writer, { job = job, cb = cb.err or {} }),
  }, function(exit)
    on_exit(exit, { job = job, cb = cb.exit })
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

--- @return integer
function Job:buf()
  local buf = self.buffer
  local bufopts = buf.opts

  local name = bufopts.name
  if not name then
    name = string.format('[Job %s]', self.id)
  end

  if bufu.loaded_p(buf.nr) then
    bufu.name(buf.nr, name)
    return buf.nr
  elseif bufu.valid_p(buf.nr) then
    -- delete if valid but not loaded
    bufu.delete(buf.nr)
  end

  -- buffer we don't own, but using the name we want
  local target = bufu.nr(name)
  if target > 0 then
    bufu.delete(target)
  end

  local new = bufu.new(name)
  buf.nr = new

  api.nvim_create_autocmd('BufDelete', {
    buffer = new,
    callback = function()
      if self.exit then
        return
      end
      vim.notify(string.format('%s will continue to run', self.id))
    end,
    group = api.nvim_create_augroup('Compilation', { clear = true }),
  })

  if bufopts.headercb then
    buf.header = bufopts.headercb()
    bufu.append(buf.nr, buf.header)
  end

  if #self.output > 0 then
    bufu.append(new, self.output)
  end

  if self.exit and bufopts.footercb then
    buf.footer = bufopts.footercb(self.exit, self.output)
    bufu.append(buf.nr, buf.footer)
  end

  if bufopts.confcb then
    bufopts.confcb(new)
  end

  return new
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
  if jobs[id] and #jobs[id].old > 0 then
    return jobs[id].old[#jobs[id].old]
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
