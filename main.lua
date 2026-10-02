
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


-- =====================================================================
-- Virtual "back" entry
-- =====================================================================
-- A fake folder shown inside the jumplist. Entering it takes you back to
-- the directory you were in before jumping into the jumplist. It is not
-- a junction or symlink: exactly like the drive-list trick, it is an
-- empty placeholder directory that we create just-in-time before
-- entering the jumplist and delete again when leaving.
--
-- NOTE: Windows does not allow a real folder literally named "..", so we
-- use "@back". Yazi's default icon rules render "@*" names with the
-- parent-directory arrow, so it still looks like "..". If your theme
-- does not, prepend this rule to the icon section of your yazi.toml:
--   { url = "file://**/@back", is_dir = true, text = " 󰄒 ", style = "cyan" }

if JL:sub(-1) ~= "\\" and JL:sub(-1) ~= "/" then
	JL = JL .. "\\"
end
local VNAME = "@back"
local VPATH = JL .. VNAME      -- full path of the virtual entry

-- Where we were before entering the jumplist, normalized with "/" separators
-- (nil while not inside it).
local origin = nil

-- The origin as a plain filesystem path for ya.emit("cd"). Yazi's Url adds a
-- "file://" prefix when stringified on some platforms, so strip it defensively.
local function origin_path()
	local o = tostring(origin)
	if o:sub(1, 7) == "file://" then o = o:sub(8) end
	return o
end

-- Create the empty placeholder dir. Best-effort: if it fails (e.g. no
-- write access), everything else keeps working, there is simply no
-- visible "back" entry.
local function create_virtual()
	pcall(fs.create, "dir_all", Url(VPATH))
end

-- Remove the placeholder again. fs.remove("dir") only deletes empty
-- directories, so this can never destroy real content.
local function remove_virtual()
	pcall(fs.remove, "dir", Url(VPATH))
end

-- Normalize a directory path for comparisons: unify separators, strip
-- trailing ones, but keep drive roots distinguishable ("C:" -> "C:/").
local function normalize(p)
	p = tostring(p):gsub("\\", "/")
	if p:match("^%a:$") then return p .. "/" end
	local rooted = p:match("^[A-Za-z]:/")
	p = p:gsub("/+$", "")
	if p == "" then p = rooted and rooted:sub(1, 2) or "/" end
	return p
end

local JLN = normalize(JL)      -- e.g. "C:/Apps/JumpList"
local VLN = normalize(VPATH)   -- e.g. "C:/Apps/JumpList/@back"

local function starts_with(s, prefix)
	return s == prefix or s:sub(1, #prefix + 1) == prefix .. "/"
end

local function setup(state, options)

	-- Intercept 'cd' commands
	ps.sub("cd", function(self)
		-- Ignore self-emitted events to avoid re-entrancy loops.
		if self and self._src then return end

		-- Ensure jumplist path ends with backslash for prefix matching
		local jl = JL

		-- Get the current working directory (Url object)
		local cwd = get_current_dir_path()
		local cwd_str = tostring(cwd)
		local norm = normalize(cwd_str)

		-- Clean up whenever we end up somewhere outside the jumplist:
		-- drop the virtual "back" placeholder and forget the origin.
		if origin and norm ~= JLN and not starts_with(norm, JLN) then
			d("leaving jumplist, clearing origin")
			remove_virtual()
			origin = nil
		end

		if cwd_str ~= jl and starts_with(norm, JLN) then
			d("cwd = "..cwd)

			-- Enter on the virtual "back" entry? Redirect straight to where
			-- we came from. We deliberately do NOT delete the placeholder
			-- here: yazi removes it automatically because it is an empty dir
			-- (same behaviour the drive-list plugin relies on), and the
			-- cleanup above catches any case where that did not happen.
			if norm == VLN and origin then
				d("  virtual back -> " .. origin)
				ya.emit("cd", { origin_path() })
				return true -- Cancel the original cd action
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
	entry = function()
		local cwd_str = get_current_dir_path()
		local norm = normalize(cwd_str)

		-- Already inside the jumplist (or on its virtual "back" entry)?
		-- Pressing the key again acts as "leave": go straight back to
		-- where we entered from.
		if norm == JLN or starts_with(norm, JLN) then
			if origin then
				remove_virtual()
				ya.emit("cd", { origin_path() })
			else
				ya.emit("leave", {})
			end
			return
		end

		-- Entering the jumplist: remember the previous directory
		-- (normalized so comparisons and re-emission are separator-stable)...
		origin = normalize(norm)
		-- ...and create the virtual "back" placeholder first, so the very
		-- first listing of the jumplist already shows it.
		create_virtual()

		ya.emit("cd", { Url(JL) })
	end,
}
