
-- Default path if not specified by the user, add \\ for windows
local JL = "C:\\Apps\\JumpList\\"

-- Name of the virtual ".." entry shown at the top of the jumplist.
-- It is NOT a real folder: like the drive-list trick (creating empty
-- placeholder dirs on demand), we create it just-in-time so yazi can
-- hover/enter it, and remove it again when we leave.
local VNAME = ".."

local function d(...)
	--ya.dbg(...)
end


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
        target = target:gsub("^\\\\%?\\", ""):gsub("^%?%?\\", ""):gsub("^\\\\%?\\", ""):gsub("^%?%?\\", ""):gsub("^\\%?%?\\", "")
        return target
    end

    -- Pattern 2: Sometimes "Substitute Name" is more reliable, especially for raw junctions
    target = output:match("Substitute Name:%s*([^\r\n]+)")
    if target then
        -- Remove common prefixes like \??\ or \\?\
		target = target:gsub("^\\\\%?\\", ""):gsub("^%?%?\\", ""):gsub("^\\\\%?\\", ""):gsub("^%?%?\\", ""):gsub("^\\%?%?\\", "")        
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


-- Remember where we were before jumping into the jumplist, so we can
-- navigate back out via the virtual ".." entry.
local origin = nil

-- Normalize a directory path to a comparable form: unify separators and
-- strip trailing ones (drive roots keep the trailing "\" like get_current_dir_path does).
local function normalize(p)
  p = tostring(p):gsub("\\", "/")
  if p:match("^%a:$") then return p .. "/" end -- bare drive letter -> root
  local rooted = p:match("^[A-Za-z]:/")        -- "C:/..." keeps its root slash
  p = p:gsub("/+$", "")
  if p == "" then p = rooted and rooted:sub(1, 2) or "/" end
  return p
end

-- Parent of a normalized path.
local function parent_of(p)
  local pp = p:gsub("/+$", "")
  local cut = pp:match("^(.*/)")
  if cut then
    cut = cut:gsub("/+$", "")
    if cut ~= "" then return cut end
    if pp:match("^[A-Za-z]:") then return pp .. "/" end -- "C:" -> "C:/" (root)
    return "/"                                           -- "/x" -> "/"
  end
  return nil -- already at root ("/" or "C:/")
end

-- Create the empty virtual ".." placeholder inside the jumplist dir.
local function create_virtual(origin_path)
  local ok, err = fs.create("dir_all", Url(JL .. VNAME))
  if not ok then
    ya.notify {
      title = "Jumplist",
      content = "Failed to create virtual '" .. VNAME .. "' entry: " .. tostring(err),
      level = "error",
      timeout = 5,
    }
  else
    -- Persist the origin path inside the fake dir. It doubles as a
    -- fallback: if yazi ever restores a session into this dir without
    -- the plugin having set `origin`, the cd handler reads this file.
    local wok, werr = fs.write_all(Url(JL .. VNAME .. "\\@jumplist-origin"), origin_path)
    if not wok then
      ya.notify {
        title = "Jumplist",
        content = "Failed to write origin marker: " .. tostring(werr),
        level = "error",
        timeout = 5,
      }
    end
  end
end

-- Remove the virtual placeholder (only works while it is empty).
local function remove_virtual()
  fs.remove("dir", Url(JL .. VNAME))
end



local function setup(state, options)
	
	-- Intercept 'cd' commands
	ps.sub("cd", function()
		-- Ensure jumplist path ends with backslash for prefix matching
		local jl = JL
						
		-- Get the current working directory (Url object)
		local cwd = get_current_dir_path()		
		local cwd_str = tostring(cwd)

		-- Leaving the jumplist (or its virtual ".." dir)? Clean up.
		if origin and cwd_str ~= jl and cwd_str:sub(1, #jl) ~= jl then
			d("leaving jumplist, clearing origin")
			remove_virtual()
			origin = nil
		end

		if cwd_str ~= jl and cwd_str:sub(1, #jl) == jl then
			d("cwd = "..cwd)
			
			-- Opening the virtual ".." entry: go back where we came from.
			if cwd_str == jl .. VNAME then
				local prev = origin
				if not prev then
					-- We got here without the plugin having set origin
					-- (e.g. yazi restored the session into the fake dir);
					-- fall back to the persisted marker file.
					prev = fs.read_all(Url(jl .. VNAME .. "\\@jumplist-origin"))
					if prev then prev = tostring(prev) end
				end
				if prev and prev ~= "" then
					d("  virtual .. -> " .. prev)
					remove_virtual()
					ya.emit("cd", { prev })
					return true -- Cancel the original cd action
				else
					d("  virtual .. has no known origin, falling through")
				end
			end
			
			-- Attempt to get the target using fsutil
			local real_target = get_junction_target_fsutil(cwd_str)
			if real_target and real_target ~= "" then				
				d("    target = "..real_target)					
				ya.emit("cd", { real_target })
				return true -- Cancel the original cd action
			else
			end
						
		end		
	end)
end

--- @sync entry
return {
	setup = setup,	
	entry = function(_, job)
		local cwd_str = get_current_dir_path()

		-- Already inside the jumplist? Pressing the key again acts as
		-- "leave": go straight back to where we entered from.
		if cwd_str:sub(1, #JL) == JL then
			if origin then
				remove_virtual()
				ya.emit("cd", { origin })
			else
				ya.emit("leave", {})
			end
			return
		end

		-- Entering the jumplist: remember the previous directory first...
		local prev = normalize(cwd_str)
		local jln = normalize(JL)
		-- ...but never record a location inside the jumplist itself;
		-- in that (edge) case fall back to the jumplist's parent.
		if prev ~= jln and prev:sub(1, #jln) ~= jln and prev:sub(1, #jln + 1) ~= jln .. "/" then
			origin = prev
		else
			origin = parent_of(jln)
		end

		-- ...then create the virtual ".." entry (a just-in-time placeholder
		-- dir, like the drive-list trick) and jump in.
		create_virtual(origin)

		ya.emit("cd", { JL })
	end,
}
