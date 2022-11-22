---------------------------------------------------------------------------------------
-- Copas-friendly true asynchronous threads, powered by Lua Lanes.
--
-- When loaded this module will initialize LuaLanes by calling
-- `lanes.configure()` without arguments. If you don't want/need that, then
-- call `lanes.configure` before loading/requiring this module.
--
-- @copyright Copyright (c) 2016 Hisham Muhammad
-- @author Hisham Muhammad
-- @license MIT, see `LICENSE.md`.
-- @name copas-async
-- @class module

local async = {}

local lanes = require("lanes")
local copas = require("copas")
local socket = require("socket")

if lanes.configure then
   lanes.configure()
end

local pack, unpack do -- pack/unpack to create/honour the .n field for nil-safety
   local _unpack = _G.table.unpack or _G.unpack
   function pack (...) return { n = select('#', ...), ...} end
   function unpack(t, i, j) return _unpack(t, i or 1, j or t.n or #t) end
 end

local function normalize_exit(ret, typ, cod)
   if type(ret) == "number" then
      if ret == 0 then
         return true, "exit", 0
      elseif ret < 255 then
         return nil, "signal", ret
      else
         return nil, "exit", math.floor(ret / 255)
      end
   else
      return ret, typ, cod
   end
end

local whost, wport
local add_waiting_coro

do -- wakeup server
   local waiting = {}

   local wskt = socket.bind("*", 0)
   whost, wport = wskt:getsockname()
   wport = tonumber(wport)

   local function remove_waiting_coro(id)
      local coro = waiting[id]
      waiting[id] = nil
      if not next(waiting) then
         copas.removeserver(wskt, true) -- keep the server socket open
      end
      return coro
   end

   local function launch_wakeup_server()
      copas.addserver(wskt, function(dskt)
         local id = ""
         while true do
            local data, err, partial = dskt:receive()
            if data == nil then
               if partial then
                  id = id .. partial
               end
            else
               id = id .. data
            end
            if err == "closed" then
               break
            end
         end
         dskt:close()
         local coro = remove_waiting_coro(id)
         if coro then
            copas.wakeup(coro)
         end
      end)
   end

   function add_waiting_coro(id, coro)
      local empty = not next(waiting)
      waiting[id] = coro
      if empty then
         launch_wakeup_server()
      end
   end
end

-- Called in the async thread when results are ready to be send to the
-- owning coroutine on the copas side.
-- Sends the type and the data over the Linda, then
-- creates a socket, connects to the wakeup server, and send the stringified
-- Linda (eg. "Linda: 0xfaf38c0"), as ID of the targetted Linda.
-- The wakeup server (in the copas environment), will find the appropriate coroutine and resume it.
-- @param ch the Lanes Linda object
-- @param ch_id "done", "data", "result", etc.
-- @param ... the data to be packed and send over the linda
-- @return nothing
local function awake_future(ch, ch_id, ...)
   local socket = require("socket")
   ch:send(ch_id, pack(...))
   local cskt = socket.tcp()
   local ok = cskt:connect(whost, wport)
   if ok then
      cskt:send(tostring(ch))
   end
   cskt:close()
end

--- An object that can be queried later to obtain the result of an async function.
-- See `async.addthread`.
-- @type future
-- @tparam linda ch the linda to operate on
-- @param ch_id, the linda key to look for ("done", "data", etc.)
local function new_future(ch, ch_id)
   local future = {
      res = nil,     -- will hold the packed results of the function call
      getting = nil, -- lock; to prevent concurrent access
      dead = false,  -- if truthy, the function is done
   }



   --- Obtains the result value of the async thread function if it is already available,
   -- or returns `false` if it is still running. This function always returns immediately.
   -- @function future:try
   -- @return `true + ...` (the async function results) when complete, or `false` if not yet available
   -- @usage
   -- local msg = "hello"
   -- copas(function()
   --    -- schedule a thread using LuaLanes
   --    local future = async.addthread(function()
   --       os.execute("for i in seq 5; do echo 'thread says "..msg.." '$i; sleep 1; done")
   --       return 123
   --    end)
   --
   --    -- loop to wait for result
   --    local done, result
   --    while not done do
   --       copas.sleep(0.1)
   --       done, result = future:try()
   --    end
   --
   --    assert(123 == future(), "expected exit code 123")
   -- end)
   future.try = function()
      assert(not future.getting, "concurrent access to future")

      if not future.res then
         local key, value = ch:receive(0, ch_id)
         if key then
            future.res = value
            future.dead = true
         end
      end

      if future.res then
         return future.dead, unpack(future.res)
      end
      return future.dead
   end

   --- Waits until the async thread finishes (without locking other Copas coroutines) and
   -- obtains the result values of the async thread function.
   --
   -- Calling on the future object is a shortcut to this `get` method.
   -- @function future:get
   -- @return ... the async function results
   -- @usage
   -- local msg = "hello"
   -- copas(function()
   --    -- schedule a thread using LuaLanes
   --    local future = async.addthread(function()
   --       os.execute("for i in seq 5; do echo 'thread says "..msg.." '$i; sleep 1; done")
   --       return 123
   --    end)
   --
   --    -- The following will wait for the thread to complete (5 secs)
   --    -- Note: calling `future()` is the same as `future:get()`
   --    assert(123 == future(), "expected exit code 123")
   -- end)
   future.get = function()
      future.getting = assert(not future.getting, "concurrent access to future")

      if not future.dead then
         local key, value = ch:receive(0, ch_id)
         if not key then
            add_waiting_coro(tostring(ch), coroutine.running())
            copas.sleep(-1)
            key, value = ch:receive(0, ch_id)
         end
         if key then
            future.res = value
         end
         future.dead = true
      end

      future.getting = false
      if future.res then
         return unpack(future.res)
      end
   end
   setmetatable(future, { __call = future.get })
   return future
end


--- Async module
-- @section async

--- Runs a function in its own thread, and returns a `future`.
--
-- Note that the function runs it its own Lanes context, so upvalues are
-- copied into the function. When modified in that function, it will not update
-- the original values living Copas side.
-- @tparam function fn the function to execute async
-- @return a `future`
function async.addthread(fn)
   local ch = lanes.linda()

   lanes.gen("*", function()
      -- FIXME PCALL TEST
      awake_future(ch, "done", fn())
   end)()

   return new_future(ch, "done")
end



--- Convenience function that runs an os command in its own async thread.
-- This allows you to easily run long-lived commands in your own coroutine without
-- affecting the Copas scheduler as a whole.
--
-- This function causes the current coroutine to wait until the command is finished,
-- without locking other coroutines (in other words, it internally runs `get()`
-- in its `future`).
-- @tparam string command The command to pass to `os.execute` in the async thread.
-- @return ok, type, code [same as in `os.execute` for Lua 5.3](https://www.lua.org/manual/5.3/manual.html#pdf-os.execute)
-- (even when running on Lua 5.1).
function async.os_execute(command)
   local future = async.addthread(function()
      return os.execute(command)
   end)
   return normalize_exit(future:get())
end



--- Convenience function that runs `io.popen(command, mode)` in its own async thread.
-- This allows you to easily run long-lived commands in your own coroutine and get
-- their output (async) without affecting the Copas scheduler as a whole.
--
-- This function returns (immediately) a descriptor object with an API that matches that of the
-- object returned by `io.popen` in Lua 5.3. When commands are issued, this causes
-- the current coroutine to wait until the response is returned, without locking
-- other coroutines (in other words, it uses `future` internally). Only the
-- methods `fd:read`, `fd:write`, `fd:close`, and `fd:lines` are currently supported.
-- @tparam string command The command to pass to `io.popen` in the async thread.
-- @tparam string mode The mode to pass to `io.popen` in the async thread.
-- @return descriptor object
function async.io_popen(command, mode)
   mode = mode or "r"
   local ch = lanes.linda()

   async.addthread(function()
    local fd, err = io.popen(command, mode)
      if not fd then
         return nil, err
      end
      local op = mode == "r" and "read" or "write"
      while true do
         local _, fd_cmd = ch:receive("fd_cmd")
         if fd_cmd == "close" then
            awake_future(ch, "result", normalize_exit(fd:close()))
            break
         end
         if fd_cmd == nil then
            -- on the C-side of things passing nil is not the same as not
            -- passing anything
            awake_future(ch, "result", fd[op](fd))
         else
            awake_future(ch, "result", fd[op](fd, fd_cmd))
         end
      end
      fd:close()
   end)

   local function operation(valid_mode, errormsg_on_invalid)
      return function(_, arg)
         if mode ~= valid_mode then
            return nil, errormsg_on_invalid
         end
         local ok = ch:send("fd_cmd", arg)
         if ok == true then
            return new_future(ch, "result")()
         end
      end
   end

   return {
      close = function()
         local ok = ch:send("fd_cmd", "close")
         if ok == true then
            return new_future(ch, "result")()
         end
      end,
      flush = function()
         return nil, "Not available."
      end,
      lines = function(self)
         return function()
            return self:read()
         end
      end,
      read = operation("r", "Pipe not open for reading"),
      seek = function()
         return nil, "Not available."
      end,
      setvbuf = function()
         return nil, "Not available."
      end,
      write = operation("w", "Pipe not open for writing"),
   }
end

return async
