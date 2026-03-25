---------------------------------------------------------------------------------------
-- Copas-friendly true asynchronous threads, powered by Lua Lanes.
--
-- When loaded this module will initialize LuaLanes by calling
-- `lanes.configure()` without arguments. If you don't want/need that, then
-- call `lanes.configure` before loading/requiring this module.
--
-- @copyright Copyright (c) 2016 Hisham Muhammad, 2022-2023 Thijs Schreijer
-- @author Hisham Muhammad
-- @license MIT, see `LICENSE.md`.
-- @name copas-async
-- @class module
-- @usage
-- local async = require "copas.async"
--
-- local function sometask()
--   -- do something that takes a while
--   return ok, err
-- end
--
-- local ok, err = async(sometask)

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


-- Module table
local async = {
   -- Status constants (matching copas.future)
   SUCCESS = copas.future.SUCCESS,
   PENDING = copas.future.PENDING,
   ERROR   = copas.future.ERROR,
}

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
-- @param ... the data to be packed and send over the linda (first value is the ok flag)
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
   local fut = {
      results = nil, -- packed results: first value is ok-flag (true/false), then the actual values
      sema = copas.semaphore.new(9999, 0, math.huge),
      waiting = false, -- true once a coroutine has registered with the wakeup server
   }

   --- Obtains the result value of the async thread function if it is already available,
   -- or returns `async.PENDING` if it is still running. This function always returns immediately.
   -- @function future:try
   -- @return `async.PENDING` (false) when still running;
   --         `async.SUCCESS` (true) + results when complete;
   --         `async.ERROR` ("error") + errmsg when the task failed.
   function fut:try()
      if not self.results then
         local key, value = ch:receive(0, ch_id)
         if key then
            self.results = value
            self.sema:give(self.sema:get_wait())
         end
      end

      if not self.results then
         return async.PENDING
      end
      if self.results[1] then
         return async.SUCCESS, unpack(self.results, 2)
      else
         return async.ERROR, self.results[2]
      end
   end

   --- Waits until the async thread finishes (without locking other Copas coroutines) and
   -- obtains the result values of the async thread function.
   --
   -- Calling on the future object is a shortcut to this `get` method.
   -- Multiple coroutines may call `get` concurrently; all will be released when the result arrives.
   -- @function future:get
   -- @return like pcall: true + results on success, false + errmsg on error
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
   --    local ok, result = future()
   --    assert(ok and 123 == result, "expected exit code 123")
   -- end)
   function fut:get()
      if not self.results then
         if not self.waiting then
            -- First caller: do the actual waiting via the wakeup server mechanism
            self.waiting = true
            local key, value = ch:receive(0, ch_id)
            if key then
               self.results = value
            else
               add_waiting_coro(tostring(ch), coroutine.running())
               copas.pauseforever()
               -- try() may have already stored the result while we were sleeping
               if not self.results then
                  key, value = ch:receive(0, ch_id)
                  if key then self.results = value end
               end
            end
            self.sema:give(self.sema:get_wait()) -- release any concurrent waiters
         else
            -- Subsequent callers: wait for the first caller to receive and release
            self.sema:take(1, math.huge)
         end
      end
      return unpack(self.results)
   end

   setmetatable(fut, { __call = function(self, ...) return self:get(...) end })
   return fut
end


--- Async module
-- @section async

--- Runs a function in its own thread, and returns a `future`.
--
-- Note that the function runs in its own Lanes context, so upvalues are
-- copied into the function. When modified in that function, it will not update
-- the original values living Copas side.
-- @tparam function fn the function to execute async
-- @return a `future`
function async.addthread(fn)
   local ch = lanes.linda()

   lanes.gen("*", function()
      local results
      local ok, err = pcall(function()
         results = pack(true, fn())
      end)
      if not ok then
         results = pack(false, err)
      end
      awake_future(ch, "done", unpack(results, 1, results.n))
   end)()

   return new_future(ch, "done")
end



--- Runs a function in its own thread, and waits for the results.
-- This will block the current thread, but will not block other Copas threads.
-- Returns like pcall: true + results on success, false + errmsg on error.
-- @tparam function fn the function to execute async
-- @return true + the function's return values, or false + errmsg
-- @usage -- assuming a function returning a value or nil+error, normally called like this;
-- --
-- --   local result, err = fn()
-- --
-- -- Can be called non-blocking like this:
--
-- local ok, result, err = async.run(fn)
-- -- or even shorter;
-- local ok, result, err = async(fn)
function async.run(fn)
   return async.addthread(fn):get()
end



--- Convenience function that runs an os command in its own async thread.
-- This allows you to easily run long-lived commands in your own coroutine without
-- affecting the Copas scheduler as a whole.
--
-- This function causes the current coroutine to wait until the command is finished,
-- without blocking other coroutines (in other words, it internally runs `get()`
-- in its `future`).
-- @tparam string command The command to pass to `os.execute` in the async thread
-- @return like pcall: true + os.execute results on success, false + errmsg on error
function async.os_execute(command)
   return async.run(function()
      return os.execute(command)
   end)
end



--- Convenience function that runs `io.popen(command, mode)` in its own async thread.
-- This allows you to easily run long-lived commands in your own coroutine and get
-- their output (async) without affecting the Copas scheduler as a whole.
--
-- This function returns (immediately) a descriptor object with an API that matches that of the
-- object returned by `io.popen`. When commands are issued, this causes
-- the current coroutine to wait until the response is returned, without locking
-- other coroutines (in other words, it uses `future` internally). Only the
-- methods `fd:read`, `fd:write`, `fd:close`, and `fd:lines` are currently supported.
-- <br/>Note: `fd:lines` is not supported on PuC Rio Lua 5.1 (yield across C boundary errors
-- will occur)
-- @tparam string command The command to pass to `io.popen` in the async thread
-- @tparam[opt="r"] string mode The mode to pass to `io.popen` in the async thread
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
            awake_future(ch, "result", true, fd:close())
            break
         end
         if fd_cmd == nil then
            -- on the C-side of things passing nil is not the same as not
            -- passing anything
            awake_future(ch, "result", true, fd[op](fd))
         else
            awake_future(ch, "result", true, fd[op](fd, fd_cmd))
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
            return select(2, new_future(ch, "result"):get())
         end
      end
   end

   return {
      close = function()
         local ok = ch:send("fd_cmd", "close")
         if ok == true then
            return select(2, new_future(ch, "result"):get())
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



return setmetatable(async, {
   __call = function(self, ...)
      return async.run(...)
   end,
   __index = function(_, k)
      error("unknown field 'async." .. tostring(k) .. "'", 2)
   end,
})
