
-- Default path if not specified by the user, add \\^ for windows
local JL = "C:\\Apps\\JumpList\\"


local function get_junction_target_fsutil(path_str)
    -- Escape backslashes and quotes for shell
    local safe_path = path_str:gsub('"', '\\"')
    local handle = io.popen('fsutil reparsepoint query "' .. safe_path .. '" 2>nul')
    if not handle then        
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    if not output or output:find("Error") or output:find("The system cannot find") then        
        return nil
    end

    -- Try multiple patterns, as fsutil output format can vary slightly
    -- Pattern 1: For junctions, often shows "Substitute Name" and "Print Name"
    local target = output:match("Print Name:%s*([^\r\n]+)")
    if target then
        -- Remove common prefixes like \??\ or \\?\
        target = target:gsub("^\\\\%?\\", ""):gsub("^%?%?\\", "")
        return target
    end

    -- Pattern 2: Sometimes "Substitute Name" is more reliable, especially for raw junctions
    target = output:match("Substitute Name:%s*([^\r\n]+)")
    if target then
        -- Remove common prefixes like \??\ or \\?\
        target = target:gsub("^\\\\%?\\", ""):gsub("^%?%?\\", "")
        return target
    end

    return nil
end


local get_current_dir_path = ya.sync(function()
  local path = tostring(cx.active.current.cwd)
  if ya.target_family() == "windows" and path:match("^[A-Za-z]:$") then
    return path .. "\\"
  end
  return path
end)




local function setup(state, options)
	
	-- Intercept 'cd' commands
	ps.sub("cd", function()
		-- Ensure jumplist path ends with backslash for prefix matching
		local jl = JL
					
		-- Get the current working directory (Url object)
		local cwd = get_current_dir_path()	
		local cwd_str = tostring(cwd)
		if cwd_str ~= jl and cwd_str:sub(1, #jl) == jl then

						
			-- Attempt to get the target using fsutil
			local real_target = get_junction_target_fsutil(cwd_str)
			if real_target and real_target ~= "" then
				ya.manager_emit("cd", { real_target })
				return true -- Cancel the original cd action
			else
			end
					
		end	
	end)
end

--- @sync entry
return {
	setup = setup,	
	entry = function()
		ya.manager_emit("cd", { JL })
	end,
}