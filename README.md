# OS-UTIL-YAZI-JumpList
As a quick jumplist feature for Yazi which can be used to quickly jump to other drives or directories by using junctions. Mainly used to make it easy to access drives in windows.

## Add key in keymap.toml:
[[mgr.prepend_keymap]]  
on  = "h"  
run = "plugin jumplist"  
desc = "A jumplist which can be used to quickly navigate to various directories."

## Create jumplist dir:
Edit main.lua to point to jumplist dir.
Add junctions/symlinks within the directory.

## Add setup to yazi/init.lua:
require("jumplist"):setup()



