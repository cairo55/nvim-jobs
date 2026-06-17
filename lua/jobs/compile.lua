-- PRELUDE --
local api = vim.api
local fn = vim.fn

local loglvl = vim.log.levels

local jobc = require("jobs/control")
local bufu = require("jobs/bufutil")

local o = vim.o

-- TYPES --

--- @class CompilationEntryFile
--- @field value    string
--- @field startpos integer
--- @field endpos   integer

--- @class CompilationEntryLine
--- @field value    integer
--- @field startpos integer
--- @field endpos   integer

--- @class CompilationEntryColumn
--- @field value    integer
--- @field startpos integer
--- @field endpos   integer

--- @class CompilationEntrySeverity
--- @field value    vim.diagnostic.Severity
--- @field startpos integer
--- @field endpos   integer

--- @class CompilationEntry
--- @field lnum?     integer
--- @field file      CompilationEntryFile
--- @field line      CompilationEntryLine
--- @field column?   CompilationEntryColumn
--- @field severity? CompilationEntrySeverity

-- STATE --

--- @type integer?
local current = nil

--- @type CompilationEntry[]
local entries = {}

--- @type (fun(line: string): CompilationEntry)[]
local extract = {}

-- ENTRIES --

--- @param entry CompilationEntry
--- @return boolean
local function setentry(entry)
    local file   = entry.file.value
    local row    = entry.line.value
    local column = entry.column and entry.column.value - 1 or nil

    local bufnr = bufu.nr(file)
    if bufnr > 0 then
        -- if there's already a special buffer with that name, just do nothing
        if vim.bo[bufnr].buftype ~= "" then
            return false
        end
    end

    local added = false
    if bufnr == 0 then
        if not fn.filereadable(file) then
            return false
        end
        bufnr = fn.bufadd(file)
        added = true
    end

    if not bufu.loaded_p(bufnr) then
        -- TODO: properly handle existence of swap files
        --
        -- <https://github.com/neovim/neovim/issues/40263>
        --
        -- `bufload()` throws an error if the buffer has an associated swap
        -- file. Ideally we would edit anyway, as in `v:swapchoice = 'e'`, but
        -- `SwapExists` doesn't trigger for `bufload()`. What happens instead is
        -- that a massive error message is printed, and the buffer gets a read
        -- error indicator. We can't do anything about this for now, so we just
        -- cancel.
        local ok = pcall(fn.bufload, bufnr)
        if not ok then
            if added then bufu.delete(bufnr) end
            return false
        end
    end

    if not bufu.posvalid_p(bufnr, row, column) then
        if added then bufu.delete(bufnr) end
        return false
    end

    bufu.current(bufnr)
    api.nvim_win_set_cursor(0, { row, column })
    return true
end

--- @param entry CompilationEntry
local function shouldjump(entry)
    local fname = fn.expand("%:t")
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))

    if entry.file.value ~= fname then
        return true
    end

    if entry.line.value ~= row then
        return true
    end

    if entry.column and entry.column.value ~= col + 1 then
        return true
    end

    return false
end

local function next()
    if #entries == 0 then
        vim.notify("No entries", loglvl.WARN)
        return
    end

    local new = (current or 0) + 1
    local start = new
    while new <= #entries do
        local entry = entries[new]
        if shouldjump(entry) and setentry(entry) then
            local diff = new - start
            if diff > 0 then
                vim.notify(string.format("Skipped %i entries", diff), loglvl.WARN)
            end
            current = new
            return
        end
        new = new + 1
    end

    vim.notify("No subsequent entries", loglvl.WARN)
end

local function prev()
    if #entries == 0 then
        vim.notify("No entries", loglvl.WARN)
        return
    end

    local new = (current or #entries + 1) - 1
    local start = new
    while new > 0 do
        if setentry(entries[new]) then
            local diff = start - new
            if diff > 0 then
                vim.notify(string.format("Skipped %i entries", diff), loglvl.WARN)
            end
            current = new
            return
        end
        new = new - 1
    end

    vim.notify("No previous entries", loglvl.WARN)
end

-- HIGHLIGHTING --

local function hl(bufnr, hl_group, row, startcol, endcol)
    local ns = api.nvim_create_namespace("Compilation")
    api.nvim_buf_set_extmark(bufnr, ns, row-1, startcol-1, {
        end_row = row-1,
        end_col = endcol,
        hl_group = hl_group
    })
end

--- @param entry CompilationEntry
local function hlentry(bufnr, entry)
    local lnum     = entry.lnum
    local file     = entry.file
    local line     = entry.line
    local column   = entry.column
    local severity = entry.severity

    hl(bufnr, "compilationEntryFile", lnum, file.startpos, file.endpos)

    if line then
        hl(bufnr, "compilationEntryLine", lnum, line.startpos, line.endpos)
    end

    if column then
        hl(bufnr, "compilationEntryColumn", lnum, column.startpos,
                                                  column.endpos)
    end

    local sevhl = {
        [vim.diagnostic.severity.ERROR] = "compilationEntrySeverityError",
        [vim.diagnostic.severity.WARN]  = "compilationEntrySeverityWarn",
        [vim.diagnostic.severity.INFO]  = "compilationEntrySeverityInfo"
    }
    if severity then
        hl(bufnr, sevhl[entry.severity.value], lnum, severity.startpos,
                                                     severity.endpos)
    end
end

-- JOB --

--- @param cmd string|table
--- @param extractors? CompilationEntry
local function compile(cmd, extractors)
    extractors = extractors or extract

    current = nil
    entries = {}

    local function post(job, lineinfo)
        for _, li in ipairs(lineinfo) do
            for _, extractor in ipairs(extractors) do
                local entry = extractor(li.line)
                if entry then
                    entry.lnum = li.lnum
                    table.insert(entries, entry)
                    local buf = job.buffer
                    if bufu.loaded_p(buf.nr) then
                        hlentry(buf.nr, entry)
                    end
                end
            end
        end

        local bufnr = job.buffer.nr
        local wins = fn.win_findbuf(bufnr)
        for _, win in ipairs(wins) do
            local row = api.nvim_win_get_cursor(win)[1]
            local lc = api.nvim_buf_line_count(job.buffer.nr)
            if row == lc - #lineinfo and row > #job.buffer.header then
                api.nvim_win_set_cursor(win, {lc, 0})
            end
            vim.api.nvim_win_call(win, function()
                local wh = api.nvim_win_get_height(0)
                fn.winrestview({
                    topline = math.ceil(math.max(1, row - wh/2))
                })
            end)
        end
    end

    local function header()
        local cmds
        if type(cmd) == "string" then
            cmds = string.format("%s", cmd)
        else
            local args = {}
            for _, s in ipairs(cmd) do
                table.insert(args, string.format('"%s"', s))
            end
            cmds = string.format("cmd: [ %s ]", table.concat(args, ", "))
        end
        return {
            string.format("%s", fn.fnamemodify(fn.getcwd(), ":~")),
            "",
            cmds
        }
    end

    local start = vim.uv.clock_gettime("monotonic")
    local function footer(exit)
        local now = vim.uv.clock_gettime("monotonic")

        local status = ""

        local c = exit.code + exit.signal
        if c == 0 then
            status = "Compilation succeeded"
        else
            status = string.format("Compilation failed with code %i", c)
        end

        if now and start then
            local sec = (now.sec - start.sec)
                      + (now.nsec - start.nsec) / 1000000000
            status = status .. string.format(", duration %.2f s", sec)
        end

        return { "", status }
    end

    local function conf(bufnr)
        vim.bo[bufnr].filetype = "compilation"
        vim.keymap.set("n", "<C-k>", prev, { buf = bufnr })
        vim.keymap.set("n", "<C-j>", next, { buf = bufnr })
        for _, entry in ipairs(entries) do
            hlentry(bufnr, entry)
        end
    end

    local jcmd = cmd
    if type(jcmd) == "string" then
        jcmd = { o.shell, o.shellcmdflag, jcmd }
    end

    local job = jobc.start("Compilation", jcmd, {
        buf = {
            name     = "[Compilation]",
            headercb = header,
            footercb = footer,
            confcb   = conf,
        },
        cb = {
            out = { post = post },
            err = { post = post }
        },
    })

    if not job then
        vim.notify("A compilation process is already running", loglvl.WARN)
        return
    end

    local buf = job:buf()
    bufu.current(buf)
    api.nvim_win_set_cursor(0, {#job.buffer.header, 0})
end

-- SETUP --

local function setup()
    for _, hl in ipairs({
        {
            name = "compilationEntryFile",
            link = "Directory"
        },
        {
            name = "compilationEntryLine",
            link = "Underlined"
        },
        {
            name = "compilationEntryColumn",
            link = "Underlined"
        },
        {
            name = "compilationEntrySeverityError",
            link = "DiagnosticError"
        },
        {
            name = "compilationEntrySeverityWarn",
            link = "DiagnosticWarn"
        },
        {
            name = "compilationEntrySeverityInfo",
            link = "DiagnosticInfo"
        },
    }) do
        api.nvim_set_hl(0, hl.name, { default = true, link = hl.link })
    end

    local function compile_cmd(opts)
        local args = opts.args
        if args ~= "" then
            compile(opts.args)
            return
        end

        local job = jobc.last("Compilation")
        if not job then
            vim.notify("No compilation buffer", loglvl.WARN)
            return
        end

        bufu.current(job:buf())
    end

    api.nvim_create_user_command("Compile", compile_cmd, {
        bang = true,
        nargs = "*",
        complete = "shellcmdline",
    })
end

-- INTERFACE --

return {
    setup   = setup,
    compile = compile,
    extract = extract,
}
