
local M = {}
local nvim = vim.api


M.merge = function(a, b)
    if type(a) == 'table' and type(b) == 'table' then
        for k,v in pairs(b) do if type(v)=='table' and type(a[k] or false)=='table' then M.merge(a[k],v) else a[k]=v end end
    end
    return a
end

-- Read the content of the temporary file

local read_file = function(tmppath)
    local file = io.open(tmppath, "r")
    if file then
      tmp_content = file:read("a")
      file:close()
    else
      --nvim.err_writeln("Error reading temporary file.")
      return
    end
    return tmp_content
end


-- Apply the sed replacements in Lua
local transform = function(tmppath)
    local tmp_content = read_file(tmppath)
    tmp_content = tmp_content:gsub("$\\begin{aligned}", "\n\n$$\n\\begin{gathered}")
        :gsub("\\end{aligned}$$", "\\end{gathered}\n$$\n\n")
        :gsub("$\\begin{array}", "\n$$\n\\begin{array}")
        :gsub("\\end{array}$$", "\\end{array}\n$$\n")
        :gsub("%s*\n\\end{gathered}", "\\end{gathered}")
        :gsub("%s*\n(\\end{.*})", " %1") -- This one is a bit trickier to directly translate the N command
        :gsub("$\\begin{array}", "\n$$\n\\begin{array}")
        :gsub("\\end{array}\n$$", "\\end{array}\n$$\n")
        :gsub("$\\begin{gathered}", "\n\n$$\n\\begin{gathered}")
        :gsub("\\end{gathered}\n$$", "\\end{gathered}\n$$\n")
        :gsub("::: bcode", "```")
        :gsub(":::", "```\n")
        :gsub("::toc", "\\tableofcontents")
        :gsub("<!--center-->", "\\begin{center}")
        :gsub("<!--endcenter-->", "\\end{center}")
    return tmp_content
end

local write_back = function(tmp_content,tmppath)
    -- Write the modified content back to the temporary file
    local file = io.open(tmppath, "w")
    if file then
        file:write(tmp_content)
        file:close()
    else
        --nvim.err_writeln("Error writing to temporary file.")
        return
    end

end

local comp_exit = function(tmppath)
    return  function(obj)
        --print("Compilation Done with code: "..obj.code.."Error "..obj.stderr.." and out"..obj.stdout)
        if obj.stderr ~= "" then
            print("Compilation Error: "..obj.stderr)
        end
        vim.schedule(function() vim.fs.rm(tmppath) end)
    end
end


M.pamdexmagic = function(input_file,config)
    if not input_file then
      --nvim.err_writeln("Error: Input file not specified.")
      return
    end


    local fname = vim.fn.fnamemodify(input_file,":t:r")
    local odir = vim.fn.fnamemodify(input_file,":p:h")

    if config.output_path ~= "default" then
        odir = config.output_path
    end
    local ofile = odir.."/" .. fname .. ".pdf"
    local tmpfilename = os.tmpname()
    local tmpfile = vim.fn.fnamemodify(tmpfilename,":t")
    local tmppath = odir .. "/." .. tmpfile .. ".md"


    vim.fn.system({"rm",tmpfilename})

    local copy_command = "cp " .. vim.fn.shellescape(input_file) .. " " .. vim.fn.shellescape(tmppath)
    local copy_exit_code = vim.fn.system(copy_command)
    
    if copy_exit_code ~= 0 then
        --nvim.err_writeln("Error copying file.")
        --return
    end


    local transformed = transform(tmppath)
    write_back(transformed,tmppath)


    vim.system({
        config.pandoc,
        tmppath,
        "--to", "pdf",
        "--from", "markdown+yaml_metadata_block",
        "--template", config.template,
        "--pdf-engine", config.pdf_engine,
        "--highlight-style", "pygments",
        "-o", ofile
    },{text=true},comp_exit(tmppath))


    return ofile;

end

return M;
