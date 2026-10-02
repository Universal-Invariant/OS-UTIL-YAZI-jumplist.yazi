# OS-UTIL-YAZI-JumpList
As a quick jumplist feature for Yazi which can be used to quickly jump to other drives or directories by using junctions. Mainly used to make it easy to access drives in windows.

## Add key in keymap.toml:
[[mgr.prepend_keymap]]  
on  = "h"  
run = "plugin jumplist"  
desc = "A jumplist which can be used to quickly navigate to various directories."

## Create jumplist dir:
Edit main.lua to point to jumplist dir. (Set to C:\Apps\JumpList)
Add junctions/symlinks within the directory.

## Add setup to yazi/init.lua:
require("jumplist"):setup()

<img width="2402" height="1048" alt="Screenshot 2026-10-02 075121" src="https://github.com/user-attachments/assets/b78670e5-87c0-4842-a01e-fce7c0547e41" />




