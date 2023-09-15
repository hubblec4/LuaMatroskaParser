# LuaMatroskaParser

LuaMatroskaParser is a project to parse Matroska files.
The focus is on handling the Matroska features as easy to use as possible.

## Matroska features

### Hard-Linking

There is a method to quickly scan a loaded file and detect Hard-Linking.

```lua
function Matroska_Parser:hardlinking_is_used()
```

When Hard-Linking is used there is another method to get the needed `UUID's` from the other files quickly.

```lua
function Matroska_Parser:hardlinking_get_uids()
```

### Video rotation

Matroska supports multiple rotation options and some players supports this.
There is also a non official method with the Matroska Tags which is also supported by some players.

```lua
function Matroska_Parser:get_video_rotation(vid)
```

### MKVToolNix Statistics Tags

MKVToolNix is not part of Matroska but it is the most popular tool to work with Matroska files.
MKVToolNix has a great feature called Track Statistics Tags, such Tags contains useful information.
To get such Tags quickly, there is a method:

```lua
function Matroska_Parser:find_MTX_stats_tag(track)
```
