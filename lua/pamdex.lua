-- author: Prakash
-- date: 2023-11-18
local utl = require("pamdex.utils")

local mdfile = nil
local pdffile = nil

local M = {}

local config = {
    pandoc = "pandoc",
    output_path = "/tmp",
    template = "default",
    pdf_engine = "lualatex",
    pdf_viewer = "zathura",
    title = "Merged Document",
    lua_filter = "minted.lua",
    citeproc = true,
    meta_yaml = "meta.yaml",
    pdf_engine_opts = { "--shell-escape", "-output-directory=."  },
    transforms = {
        { "$\\begin{aligned}", "\n\n$$\n\\begin{gathered}" },
        { "\\end{aligned}$$", "\\end{gathered}\n$$\n\n" },
        { "$\\begin{array}", "\n$$\n\\begin{array}" },
        { "\\end{array}$$", "\\end{array}\n$$\n" },
        { "\\f%$", "$" }, -- doxygen inline math
        { "%s*\n\\end{gathered}", "\\end{gathered}" },
        { "%s*\n(\\end{.*})", " %1" }, -- This one is a bit trickier to directly translate the N command
        { "$\\begin{array}", "\n$$\n\\begin{array}" },
        { "\\end{array}\n$$", "\\end{array}\n$$\n" },
        { "$\\begin{gathered}", "\n\n$$\n\\begin{gathered}" },
        { "\\end{gathered}\n$$", "\\end{gathered}\n$$\n" },
        { "::: bcode", "```" },
        { ":::", "```\n" },
        { "::toc", "\\tableofcontents" },
        { "<!--center-->", "\\begin{center}" },
        { "<!--endcenter-->", "\\end{center}" },
        { "\\cite{(.-)}", "[@%1]" }, -- for citation 
    },
}

local pandocgroup = vim.api.nvim_create_augroup('pandocgroupe', { clear = false })


local comp_exit = function(obj)
    print("Compilation Done with code: "..obj.code)
end

local register_autocompile = function(patterns, compile_func)
    -- Run it immediately
    compile_func()

    -- Set up an autocmd to trigger compilation automatically
    vim.api.nvim_create_autocmd({'BufWritePost'}, {
        pattern = patterns,
        group = pandocgroup,
        callback = compile_func
    })
end

local compile_dir = function(dir_name)
    local compile_func = function()
        local tmppath = utl.merge_all_md(dir_name, config)
        if tmppath then
            pdffile = utl.pamdexmagic(tmppath, config, function()
                vim.schedule(function() vim.fs.rm(tmppath) end)
            end)
            vim.notify("Compiled directory: " .. tostring(dir_name), vim.log.levels.INFO)
        end
    end

    local abs_dir = vim.fn.fnamemodify(dir_name, ":p")
    local pattern1 = abs_dir .. "*.md"
    local pattern2 = abs_dir .. "**/*.md"

    register_autocompile({pattern1, pattern2}, compile_func)
end

M.compile_start =  function(opts)
    if type(opts) == "table" and type(opts.args) == "string" and opts.args ~= "" then
        config.template = opts.args
    elseif type(opts) == "string" and opts ~= "" then
        config.template = opts
    end

    filename = vim.fn.expand("%:f")
    mdfile = vim.fn.fnamemodify(filename,":p")

    local compile_func = function()
        pdffile = utl.pamdexmagic(mdfile, config)
    end

    register_autocompile('*.md', compile_func)

    return pdffile
end

M.open_it = function()
    if pdffile == nil then
        pdffile = vim.fn.expand("%:r")..".pdf"
    end
    vim.notify("Opening "..pdffile)
    vim.cmd(":silent !"..config.pdf_viewer.." "..pdffile.." &")
end




M.setup = function(configp)
    -- if configp ~= nil then config = vim.tbl_deep_extend("force", config, configp) end
    if configp ~= nil then config = utl.merge(config,configp) end

    vim.api.nvim_create_user_command("Pamdex", function(opts)
        local fargs = opts.fargs

        if #fargs == 0 then
            M.compile_start()
            return
        end

        local cmd = fargs[1]

        if cmd == "dir" then
            local dir_name = fargs[2] or "doc"
            if compile_dir then
                compile_dir(dir_name)
            else
                vim.notify("compile_dir function is not defined", vim.log.levels.ERROR)
            end
        elseif cmd == "template" then
            local tpl_name = fargs[2]
            if tpl_name and tpl_name ~= "" then
                config.template = tpl_name
                M.compile_start()
            else
                vim.notify("Please provide a template name", vim.log.levels.ERROR)
            end
        elseif cmd == "title" then
            if fargs[2] then
                local title_str = table.concat(fargs, " ", 2)
                title_str = title_str:match("^['\"]?(.-)['\"]?$")
                config.title = title_str
                M.compile_start()
                vim.notify("Title set to: " .. title_str, vim.log.levels.INFO)
            else
                vim.notify("Please provide a title", vim.log.levels.ERROR)
            end
        else
            vim.notify("Unknown Pamdex option: " .. cmd, vim.log.levels.ERROR)
        end
    end, {
        nargs = "*",   -- zero or more arguments
        complete = function()
            return { "template", "dir", "title" }
        end
    })

end

return M

