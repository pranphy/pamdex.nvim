
local M = {}
local nvim = vim.api
local uv = vim.loop


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
        :gsub("\\f%$", "$") -- doxygen inline math
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
        :gsub("\\cite{(.-)}", "[@%1]") -- for citation 
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
        --vim.schedule(function() vim.fs.rm(tmppath) end)
    end
end


M.merge_all_md = function(dir,config)
    dir = dir or "."

    -- scan directory
    local handle = assert(uv.fs_scandir(dir))
    local files = {}

    while true do
        local name, t = uv.fs_scandir_next(handle)
        if not name then break end
        if (t == "file" or t == "link") and name:match("%.md$") then
            table.insert(files, name)
        end
    end

    table.sort(files)

    -- merge contents
    local merged = {}
    local yaml_keys = {}
    local yaml_values = {}

    local function merge_yaml_blocks(source)
        local current_key = nil
        for line in source:gmatch("([^\r\n]+)") do
            local key = line:match("^([A-Za-z0-9_.-]+)%s*:")
            if key then
                current_key = key
                if not yaml_values[key] then
                    table.insert(yaml_keys, key)
                end
                yaml_values[key] = line .. "\n"
            elseif current_key and line:match("^%s+") then
                yaml_values[current_key] = yaml_values[current_key] .. line .. "\n"
            elseif not line:match("^%s*$") then
                current_key = line
                if not yaml_values[current_key] then
                    table.insert(yaml_keys, current_key)
                end
                yaml_values[current_key] = line .. "\n"
            end
        end
    end
    
    local meta_yaml_path = dir .. "/meta.yaml"
    local meta_fd = uv.fs_open(meta_yaml_path, "r", 438)
    if meta_fd then
        local stat = assert(uv.fs_fstat(meta_fd))
        local content = assert(uv.fs_read(meta_fd, stat.size))
        uv.fs_close(meta_fd)
        
        local block = (content .. "\n"):match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n")
        if not block then block = content end
        merge_yaml_blocks(block)
    end
    
    for _, fname in ipairs(files) do
        local fullpath = dir .. "/" .. fname

        local fd = assert(uv.fs_open(fullpath, "r", 438))
        local stat = assert(uv.fs_fstat(fd))
        local content = assert(uv.fs_read(fd, stat.size))
        uv.fs_close(fd)

        local block, rest = (content .. "\n"):match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)")
        if block then
            merge_yaml_blocks(block)
            content = rest
        end

        table.insert(merged, content)
        table.insert(merged, "\n\n")
    end

    if not yaml_values["title"] then
        local current_title = config.title or "Merged Document"
        yaml_values["title"] = "title: " .. current_title .. "\n"
        table.insert(yaml_keys, 1, "title")
    end
    if not yaml_values["date"] then
        yaml_values["date"] = "date: " .. os.date("%Y-%m-%d") .. "\n"
        table.insert(yaml_keys, "date")
    end

    local final_yaml = "---\n"
    for _, k in ipairs(yaml_keys) do
        final_yaml = final_yaml .. yaml_values[k]
    end
    final_yaml = final_yaml .. "---\n\n::toc\n\n"
    
    table.insert(merged, 1, final_yaml)

    local final = table.concat(merged)

    -- generate predictable filename based on directory name
    local basename = vim.fn.fnamemodify(dir, ":p:h:t")
    if basename == "" or basename == "." then
        basename = "cur_dir"
    end
    local tmppath = "/tmp/.pamdex_" .. basename .. ".md"

    -- write file
    local out = assert(uv.fs_open(tmppath, "w", 438))
    uv.fs_write(out, final)
    uv.fs_close(out)

    return tmppath
end



M.pamdexmagic = function(input_file, config, on_completed)
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
    local tmppath = odir .. "/." .. fname .. "_pamdex_tmp.md"

    local copy_command = "cp " .. vim.fn.shellescape(input_file) .. " " .. vim.fn.shellescape(tmppath)
    local copy_exit_code = vim.fn.system(copy_command)
    
    if copy_exit_code ~= 0 then
        --nvim.err_writeln("Error copying file.")
        --return
    end

    odir = "." -- all hell breaks lose without this
    local args = {
        config.pandoc,
        tmppath,
        "--to", "pdf",
        "--from", "markdown+yaml_metadata_block",
        "--lua-filter", "minted.lua",
        "--template", config.template,
        "--pdf-engine", config.pdf_engine,
        "--columns", "800",
        "--pdf-engine-opt", "--shell-escape",
        "--pdf-engine-opt", "-output-directory="..odir,
        --"-V", "header-includes=\"\\setminted{outputdir=" .. odir .. "}\"",
        "--citeproc",
        "-o", ofile,
    }


    local transformed = transform(tmppath)
    --transformed = transformed .. "cmd : `" .. table.concat(args, " ") .. "`"
    write_back(transformed,tmppath)

    print("Running: `" .. table.concat(args, " ").."`")

    vim.system(args, { text = true }, function(obj)
        comp_exit(tmppath)(obj)
        if on_completed then on_completed() end
    end)


    return ofile;

end

return M;
