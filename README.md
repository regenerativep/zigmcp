# zigmcp

A Minecraft (Java Edition) protocol implementation in Zig. Currently supports 1.20.4
(765). Contains the protocol implementation, and a static and dynamic NBT implementation.
Depends on [jdknezek/uuid6-zig](https://github.com/jdknezek/uuid6-zig) and
[PrismarineJS/minecraft-data](https://github.com/PrismarineJS/minecraft-data).

Currently, many parts of this are probably untested. Several parts of protocol
implementation probably should be reworked, and perhaps put into separate parts of the
library for easier use. Several things may be hardcoded using information only found
from the [data generators](https://wiki.vg/Data_Generators), and it would be nice if
they were a little less hardcoded, although obtaining that data automatically through
a `zig build` may be annoying to implement (and annoying for any user of this library).

I used these sources a lot in this:

- [wiki.vg/Protocol](https://wiki.vg/Protocol)
    ([Data Generators](https://wiki.vg/Data_Generators), [NBT](https://wiki.vg/NBT),
        [Chunk Format](https://wiki.vg/Chunk_Format), etc)
- [PrismarineJS/minecraft-data](https://github.com/PrismarineJS/minecraft-data)
    (specifically the stuff for
    [1.20.2](https://github.com/PrismarineJS/minecraft-data/tree/master/data/pc/1.20.2))

Check out the `examples/` directory for some example usage. Should only need a
`zig build run` in the corresponding folder to run.

- `statusserver`: a simple server that displays a server status in the server list.
- `sniff`: a proxy that tracks connection state and displays packet ids sent between
    server and client. make sure client and server are 1.20.2, and `online-mode=false`
    and `network-compression-threshold=-1` because I haven't implemented compression or
    encryption.
