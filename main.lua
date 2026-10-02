
-- =====================================================================
-- Config
-- =====================================================================
-- Default path if not specified by the user, add \\ for windows
local JL = "C:\\Apps\\JumpList\\"

-- Name of the virtual ".." entry shown inside the jumplist.
-- It is NOT a real folder: like the drive-list trick (creating empty
-- placeholder dirs on demand), we create it just-in-time so yazi can
-- hover/enter it, and remove it again when we leave.
local VNAME = "@back"

-- The plugin subscribes to "cd". When it re-emits "cd" itself it tags the
-- event with _src so its own handler ignores it (re-entrancy guard).
-- IMPORTANT: yazi's built-in "leave" / "parent" / "hidden" / "search"
-- commands internally emit "cd" WITHOUT a _src tag. If we did not ignore
-- them, every press of `h` while hovering an entry would be swallowed by
-- the redirect logic (this was the cause of the "empty list" bug).
-- Set this to false only if you want those internal navigations to also
-- resolve junctions / trigger the back-entry.
local INTERCEPT_INTERNAL_CD = false

-- Debug logging via `ya.dbg`; enable with `;debug` in yazi.
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

-- Name of the currently hovered entry (nil when nothing is hovered).
local hovered_name = ya.sync(function()
  local h = cx.active.current.hovered
  return h and h.name or nil
end)


-- =====================================================================
-- Virtual "back" entry
-- =====================================================================
-- A fake folder shown inside the jumplist. Entering it takes you back to
-- the directory you were in before jumping into the jumplist. It is not
-- a junction or symlink: exactly like the drive-list trick, it is an
-- empty placeholder directory that we create just-in-time and delete
-- again when leaving.
--
-- HOW THE REDIRECT WORKS (and why we cannot rely on the "cd" event):
-- When yazi enters a hovered folder it emits `cd` with the PARENT as
-- `cwd` (the destination is only known afterwards through `peek`, which
-- races). So instead we remember the hovered entry at the moment the
-- user presses the key (`enter`/`leave` events fire *before* yazi
-- changes directory) and act on the resulting `cd`:
--   * cwd lands on the virtual entry itself  -> go back to origin
--   * cwd lands one level below the jumplist -> that's the folder the
--     user entered; if it is a junction, resolve its real target
--
-- NOTE: Windows does not allow a real folder literally named "..", so we
-- use "@back". To make it look like a parent entry, prepend this rule to
-- the icon section of your yazi.toml:
--   { url = "file://**/@back", is_dir = true, text = " 󰄒 ", style = "cyan" }

if JL:sub(-1) ~= "\\" and JL:sub(-1) ~= "/" then
	JL = JL .. "\\"
end
local VPATH = JL .. VNAME      -- full path of the virtual entry

-- Where we were before entering the jumplist (normalized string, nil
-- while not inside it).
local origin = nil

-- Set once setup() has registered its subscriptions. Without that, a
-- plugin run via `plugin jumplist` in the console (setup never called)
-- would set an origin nobody ever consumes, and stale state would leak
-- into later sessions.
local active = false

-- Name of the entry that was hovered when the user pressed enter/leave
-- (captured pre-navigation; consumed by the next "cd" event).
local pending_target = nil

-- Set while we emit "cd" ourselves, so our own handler ignores it.
local self_emitting = false

-- Last two cwds seen by our handlers (used to tell real moves apart from
-- re-emitted/no-op cds).
local last_cwd = nil
local prev_cwd = nil

-- Normalize a path for comparisons: unify separators, strip trailing
-- ones, but keep drive roots distinguishable ("C:" -> "C:/").
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

-- Strip any scheme/url-encoding from a Url/path string.
local function plain_path(u)
	u = tostring(u)
	u = u:gsub("^file://", "")
	u = u:gsub("%%20", " ")
	return u
end

-- The origin as a plain filesystem path for ya.emit("cd").
local function origin_path()
	return plain_path(origin)
end

-- Jumplist root without the trailing separator, e.g. "C:\Apps\JumpList".
-- Used when joining child names (avoids double separators).
local JLRAW = JL:gsub("[\\/]$", "")

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

-- Emit "cd" tagged as ours so the subscription below skips it.
-- ya.emit runs plugin event subscriptions synchronously (they all return
-- before it does), so guarding the flag around the call is enough; we
-- still restore the previous value instead of blindly clearing it, in
-- case our own emit happens while handling another one of our emits.
local function goto_(path)
	local prev = self_emitting
	self_emitting = true
	ya.emit("cd", { path })
	self_emitting = prev
end

-- Central bookkeeping for every navigation we observe: remember where we
-- came from (prev_cwd) and clear stale state when the user ends up
-- outside the jumplist.
local function track(norm)
	if norm ~= last_cwd then prev_cwd = last_cwd end
	last_cwd = norm
	if origin and norm ~= JLN and norm ~= VLN and not starts_with(norm, JLN) then
		d("leaving jumplist, clearing origin")
		remove_virtual()
		origin = nil
		pending_target = nil
	end
end

local function setup(state, options)
	active = true

	-- Remember what is hovered right before the user navigates. These
	-- events fire BEFORE yazi changes the directory, which lets us know
	-- where the user intended to go once the resulting "cd" arrives.
	ps.sub("enter", function()
		if not active then return end
		local norm = normalize(get_current_dir_path())
		track(norm)
		if starts_with(norm, JLN) then
			pending_target = hovered_name()
		else
			pending_target = nil
		end
	end)
	ps.sub("leave", function()
		if not active then return end
		local norm = normalize(get_current_dir_path())
		track(norm)
		if starts_with(norm, JLN) then
			pending_target = hovered_name()
		else
			pending_target = nil
		end
	end)

	-- Intercept 'cd' commands
	ps.sub("cd", function(self)
		-- Ignore events triggered by yazi internals ("parent"/"hidden"/
		-- "search"...). When the user enters a folder these arrive as
		-- _then == "mgr.cd". Without this filter every `h` press would be
		-- swallowed by the redirect logic (the "empty list" bug).
		-- Events emitted via ya.emit from our own code carry _src; if the
		-- keymap was bound to `plugin jumplist` directly, _then is nil.
		if not INTERCEPT_INTERNAL_CD and self and self._src ~= "jumplist"
			and self._then ~= nil and self._then ~= "mgr.cd" then
			d("ignore internal cd: " .. tostring(self._then))
			return
		end
		-- Ignore our own re-emissions to avoid re-entrancy loops.
		if self_emitting then
			d("ignore self-emitted cd")
			return
		end

		local norm = normalize(get_current_dir_path())
		track(norm)

		-- Not relevant for us? Only act while inside the jumplist.
		if not starts_with(norm, JLN) then return end

		-- Case 1: some "@back" entry became the cwd anywhere inside the
		-- jumplist tree (yazi resolved the name, or the user entered the
		-- placeholder in a subdirectory). Go back to where we came from.
		if origin and norm:match("/" .. VNAME .. "$") then
			d("virtual back -> " .. origin)
			pending_target = nil
			goto_(origin_path())
			return
		end

		-- Case 2: cwd is (still) the jumplist root and we know what was
		-- hovered when the navigation started.
		if norm == JLN and pending_target then
			local tn = normalize(pending_target):match("([^/]+)$")
			pending_target = nil

			-- The user opened the virtual "back" entry -> return home.
			if tn == VNAME then
				if origin then
					d("virtual back -> " .. origin)
					goto_(origin_path())
				else
					d("virtual back without origin -> leave tab")
					ya.emit("leave", {})
				end
				return
			end

			-- Otherwise: if the hover capture arrived late (or yazi has
			-- already descended), compare against the actual cwd; if it
			-- moved elsewhere, nothing to resolve. If it stayed at the
			-- root, yazi refused to descend into <JL>/<tn> — which it
			-- does for junctions/symlinks — so resolve the reparse point
			-- and jump to its real target.
			if normalize(last_cwd) ~= norm then return end
			local full = JLRAW .. "\\" .. tn
			local real_target = get_junction_target_fsutil(full)
			if real_target and real_target ~= "" then
				d("  junction " .. tn .. " -> " .. real_target)
				goto_(real_target)
			end
			return
		end

		-- Case 3: fallback for late/missing hover capture — if the cwd is
		-- a direct child of the jumplist root that is a junction, resolve
		-- it (covers the case where the cd event arrives after yazi
		-- already descended but the entry is a reparse point).
		if norm ~= JLN and origin then
			local child = norm:match("^" .. JLN .. "/([^/]+)$")
			if child then
				local real_target = get_junction_target_fsutil(JLRAW .. "\\" .. child)
				if real_target and real_target ~= "" then
					d("  junction(fallback) " .. child .. " -> " .. real_target)
					goto_(real_target)
				end
			end
		end
	end)
end

--- @sync entry
return {
	setup = setup,
	entry = function()
		local norm = normalize(get_current_dir_path())

		-- Already inside the jumplist (or on its virtual "back" entry)?
		-- Pressing the key again acts as "leave": go straight back to
		-- where we entered from.
		if norm == VLN or norm == JLN or starts_with(norm, JLN) then
			if origin then
				remove_virtual()
				local o = origin_path()
				origin = nil
				pending_target = nil
				goto_(o)
			else
				-- No tracked origin (e.g. yazi restarted inside the
				-- jumplist): just leave the current folder.
				ya.emit("leave", {})
			end
			return
		end

		-- Entering the jumplist: remember the previous directory...
		origin = norm
		pending_target = nil
		-- ...and create the virtual "back" placeholder first, so the very
		-- first listing of the jumplist already shows it.
		create_virtual()

		goto_(JL)

		-- If setup() was never called (no subscriptions), nobody would
		-- ever consume the redirect state; drop it immediately so it does
		-- not leak into a later session.
		if not active then
			origin = nil
		end
	end,
}
