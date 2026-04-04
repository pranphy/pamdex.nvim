local M = {}
local nvim = vim.api
local uv = vim.loop

local shadedbox = [[
\usepackage[most]{tcolorbox}
\ifdefined\Shaded
    \renewenvironment{Shaded}{}{}
\else
  \newenvironment{Shaded}{}{}
\fi
\renewenvironment{Shaded}{
  \begin{tcolorbox}[
    breakable,                % Allow code to span multiple pages
    colback=gray!5!white,    % Light background
    colframe=gray!30,        % Border color
    arc=5pt,                   % Rounded corners
    boxrule=0.5pt,             % Border thickness
    left=5pt,                  % Padding
    right=5pt,
    top=5pt,
    bottom=5pt,
    fontupper=\ttfamily
  ]
}{
  \end{tcolorbox}
}
]]

local minted_filter = [[
function CodeBlock(el)
    local lang = el.classes[1] or "text"
     local latex = "\\begin{minted}[autogobble]{" .. lang .. "}\n" .. el.text .. "\n\\end{minted}\n"
    return pandoc.RawBlock('latex', latex)
end
]]

local shaded_minted_filter = [[
function CodeBlock(el)
    local lang = el.classes[1] or "text"
    local latex = "\\begin{Shaded}\n" .. "\\begin{minted}[autogobble]{" .. lang .. "}\n" .. el.text .. "\n\\end{minted}\n" .. "\\end{Shaded}"
    return pandoc.RawBlock('latex', latex)
end
]]


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
local transform = function(tmppath, config)
    local tmp_content = read_file(tmppath)
    if config and config.transforms then
        for _, pair in ipairs(config.transforms) do
            if type(pair) == "table" and #pair == 2 then
                tmp_content = tmp_content:gsub(pair[1], pair[2])
            end
        end
    end
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
            print(obj.stderr)
        end
        vim.schedule(function() vim.fs.rm(tmppath) end)
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
    
    if config.meta_yaml and config.meta_yaml ~= "" then
        local meta_yaml_path = dir .. "/" .. config.meta_yaml
        local meta_fd = uv.fs_open(meta_yaml_path, "r", 438)
        if meta_fd then
            local stat = assert(uv.fs_fstat(meta_fd))
            local content = assert(uv.fs_read(meta_fd, stat.size))
            uv.fs_close(meta_fd)
            
            local block = (content .. "\n"):match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n")
            if not block then block = content end
            merge_yaml_blocks(block)
        end
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

    --odir = "." -- all hell breaks lose without this
    local args = {
        config.pandoc,
        tmppath,
        --"-o", ofile,
        "--to", "pdf",
        "--from", "markdown+yaml_metadata_block",
        "--pdf-engine", config.pdf_engine,
        "--columns", "700",
    }

    if config.minted  then
        table.insert(args, "-V")
        table.insert(args, [[header-includes=\usepackage[outputdir=]] .. odir .. "]{minted}")
    end

    if config.minted and config.minted_style  and config.minted_style ~= "" then
        table.insert(args, "-V")
        table.insert(args, [[\usemintedstyle{]].. config.minted_style .. "}")
    end

    if config.pdf_engine_opts and type(config.pdf_engine_opts) == "table" then
        for _, opt in ipairs(config.pdf_engine_opts) do
            table.insert(args, "--pdf-engine-opt")
            table.insert(args, opt)
        end
    end

    if config.template and config.template ~= "" then
        table.insert(args, "--template")
        table.insert(args, config.template)
    end

    if config.codebox and config.codebox ~= "" then
        table.insert(args, "-V")
        table.insert(args, "header-includes=".. shadedbox)
    end


    if config.header_includes and config.header_includes ~= "" then
        table.insert(args, "-V")
        table.insert(args, "header-includes=" .. config.header_includes)
    end

    if config.minted then
        local filter_path = odir .. "/.pamdex_filter_tmp.lua"
        local filter_file = io.open(filter_path, "w")
        if filter_file then
            if config.codebox then
                filter_file:write(shaded_minted_filter)
            else
                filter_file:write(minted_filter)
            end
            filter_file:close()
            table.insert(args, "--lua-filter")
            table.insert(args, filter_path)
        end
    end

    if config.lua_filter and config.lua_filter ~= "" then
        table.insert(args, "--lua-filter")
        table.insert(args, config.lua_filter)
    end

    if config.citeproc then
        table.insert(args, "--citeproc")
    end
    table.insert(args,"-o")
    table.insert(args,ofile)
    if config.extra_args  ~= nil and type(config.extra_args) == "table" then
        for _, arg in ipairs(config.extra_args) do
            table.insert(args, arg)
        end
    end

    local transformed = transform(tmppath, config)
    --transformed = transformed .. "cmd : `" .. table.concat(args, " ") .. "`"
    write_back(transformed,tmppath)

    if config.verbose then
        print("Running: `" .. table.concat(args, " ").."`")
    end

    vim.system(args, { text = true }, function(obj)
        comp_exit(tmppath)(obj)
        if on_completed then on_completed() end
    end)


    return ofile;

end

return M;
