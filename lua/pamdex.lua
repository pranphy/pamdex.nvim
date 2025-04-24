-- author: Prakash
-- date: 2023-11-18
local utl = require("pamdex.utils")

local mdfile = nil
local pdffile = nil

local M = {}

local config = {
    pandoc = "pandoc",
    output_path = "/tmp/pamdex/",
    template = "garamond",
    pdf_engine = "lualatex"
}

local pandocgroup = vim.api.nvim_create_augroup('pandocgroupe', { clear = false })


local comp_exit = function(obj)
    print("Compilation Done with code: "..obj.code)
end

local compile_start =  function()
    filename = vim.fn.expand("%:f")
    mdfile = vim.fn.fnamemodify(filename,":p")
    --vim.cmd(":!pantex "..filename)
    pdffile = utl.pamdexmagic(mdfile,config)
    --vim.system({"pantex ",filename},{},comp_exit)
    vim.api.nvim_create_autocmd({'BufWritePost'}, {
        pattern = '*.md',
        group = pandocgroup,
        callback = function()
            utl.pamdexmagic(mdfile,config)
        end
    })
end

function open_it()
    if pdffile == nil then
        pdfile = vim.fn.expand("%:r")..".pdf"
    end

    vim.cmd(":silent !zathura "..pdffile.." &")
end




M.setup = function(configp)
    if configp ~= nil then config = utl.merge(config,configp) end

    vim.keymap.set("n","<Leader>pm",compile_start)
    vim.keymap.set("n","<Leader>pv",open_it)

    vim.api.nvim_create_user_command("Pamdex",compile_start, {nargs='*'})
end

return M

