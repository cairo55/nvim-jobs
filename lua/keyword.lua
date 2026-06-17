-- PRELUDE --
local fn  = vim.fn
local api = vim.api

local loglvl = vim.log.levels

local jobc = require("jobctrl")
local bufu = require("bufutil")

-- STATE --

--- @type table<string, { name: string, cmd: string[] }>
local assoc = {}

-- IMPLEMENTATION --

local function keyword(kw)
    local ft = vim.bo.filetype
    if not assoc[ft] then
        vim.notify("No handler for current filetype")
        return
    end

    local cmd  = assoc[ft].cmd
    local name = assoc[ft].name

    local id = string.format("keyword %s %s", name, kw)
    local job = jobc.start(id, { unpack(cmd), kw }, {
        buf = { name = string.format("[%s %s]", name, kw) }
    })
    if not job then return end

    local buf = job:buf()
    bufu.current(buf)
end

-- COMMANDS --

local function Keyword(opts)
    local mode = fn.mode()

    -- TODO: implement visual mode
    local selection
    if opts.args ~= "" then
        selection = opts.args
    elseif mode == "n" or mode:sub(1, 2) == "ni" then
        selection = fn.expand("<cword>")
    else
        return
    end

    selection = selection:gsub("^%s*(.-)%s*$", "%1")
    if selection == "" then
        return
    end

    keyword(selection)
end

-- SETUP --

local function setup(associations)
    vim.validate("associations", associations, "table", true)
    assoc = associations

    api.nvim_create_user_command("Keyword", Keyword, {
        nargs = "*",
        desc = "Look up the current word in a help program",
    })
end

-- INTERFACE --
return {
    setup = setup,
    keyword = keyword
}
