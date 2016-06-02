
# Copas-Async

Copas-friendly true asynchronous threads, powered by Lua Lanes.

**This is alpha software, use at your own peril!**

## Example

```lua
local copas = require("copas")
local async = require("copas.async")

copas.addthread(function()
   for i = 1, 10 do
      print("coroutine A says ", i)
      copas.sleep(1)
   end
   print("DONE A")
end)

local msg = "hello"

local future = async.addthread(function()
   os.execute("for i in `seq 5`; do echo 'thread says "..msg.." '$i; sleep 1; done")
   return 123
end)

copas.addthread(function()
   copas.sleep(2)
   msg = "world" -- this will not affect the async thread
   print("coroutine B will try to get thread value")
   local val = future:try()
   if not val then
      print("coroutine B didn't get a value because thread is not done!")
   end
   print("coroutine B will wait for thread value...")
   val = future:get()
   print("coroutine B got value from thread:", val)
   local ret, typ, cod = async.os_execute("sleep 2; exit 12")
   print("coroutine B slept a bit and sleep returned: ", ret, typ, cod)
   print("DONE B")
end)

copas.loop()
```

produces:

    coroutine A says 1
    thread says hello 1
    coroutine A says 2
    coroutine B will try to get thread value
    coroutine B didn't get a value because thread is not done!
    coroutine B will wait for thread value...
    thread says hello 2
    coroutine A says 3
    thread says hello 3
    coroutine A says 4
    thread says hello 4
    coroutine A says 5
    thread says hello 5
    coroutine A says 6
    coroutine B got value from thread:123
    coroutine A says 7
    coroutine A says 8
    coroutine B slept a bit:   nil    exit    12
    DONE B
    coroutine A says 9
    coroutine A says 10
    DONE A

## Reference

#### *future* = async.addthread(*fn*)

Runs a function in its own thread, and returns a "future" (an object that can be queried
later to obtain the result of the function).

Note that the function runs it its own Lanes context, so upvalues are _copied_ into the 
function (note in the above example setting `msg` to `"world"` does not affect the
instance of `msg` running in the async thread).

#### *future*:get() 

Waits until the async thread finished (without locking other Copas coroutines) and
obtains the result value of the async thread function.

#### *future*:try() 

Obtains the result value of the async thread function if it is already available,
or returns `nil` if it is still running. This function always returns immediately.

#### *ok*, *typ*, *code* = async.os_execute(*cmd*) 

Convenience function that runs **os.execute(*cmd*)** in its own async thread.
This allows you to easily run long-lived commands in your own coroutine without
affecting the Copas scheduler as a whole.

This function causes the current coroutine to wait until the command is finished,
without locking other coroutines (in other words, it internally runs `get()`
in its future). 

The return values are the [same as in `os.execute` for Lua 5.3](http://www.lua.org/manual/5.3/manual.html#pdf-os.execute)
(even when running on Lua 5.1).

