
local async = {}

local lanes = require("lanes")
local copas = require("copas")
local socket = require("socket")
local unpack = unpack or table.unpack

lanes.configure()

local function pack(...)
   local ret = { n = select("#", ...) }
   for i = 1, ret.n do
      ret[i] = select(i, ...)
   end
   return ret
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

local wskt = socket.bind("*", 0)
local whost, wport = wskt:getsockname()
wport = tonumber(wport)

local waiting = {}

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
      local coro = waiting[id]
      waiting[id] = nil
      if not next(waiting) then
         -- HACK to stop copas.removeserver() from calling wskt:close()
         local proxy = setmetatable({ socket = wskt, close = function() end }, getmetatable(copas.wrap(wskt)))
         copas.removeserver(proxy)
      end
      if coro then
         copas.wakeup(coro)
      end
   end)
end

local function add_waiting_coro(id, coro)
   local empty = not next(waiting)
   waiting[id] = coro
   if empty then
      launch_wakeup_server()
   end
end

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

local function new_future(ch, ch_id)
   local future = {}
   future.try = function()
      if future.getting == true then
         error("concurrent access to future")
      end
      if not future.res then
         local key, value = ch:receive(0, ch_id)
         if key then
            future.res = value
            future.dead = true
         end
      end
      if future.res then
         return future.dead, unpack(future.res, 1, future.res.n)
      end
   end
   future.get = function()
      if future.getting == true then
         error("concurrent access to future")
      end
      local me = coroutine.running()
      future.getting = true
      if not future.dead then
         local key, value = ch:receive(0, ch_id)
         if key then
            future.res = value
         else
            local key, value = ch:receive(0, ch_id)
            if not key then
               add_waiting_coro(tostring(ch), me)
               copas.sleep(-1)
            end
            key, value = ch:receive(0, ch_id)
            if key then
               future.res = value
            end
         end
         future.dead = true
      end
      future.getting = false
      if future.res then
         return unpack(future.res, 1, future.res.n)
      end
   end
   setmetatable(future, { __call = future.get })
   return future
end

function async.addthread(fn)
   local ch = lanes.linda()

   lanes.gen("*", function()
      -- FIXME PCALL TEST
      awake_future(ch, "done", fn())
   end)()

   return new_future(ch, "done")
end

function async.os_execute(command)
   local future = async.addthread(function()
      return os.execute(command)
   end)
   return normalize_exit(future:get())
end

function async.channel()
   local ch = lanes.linda()
   
   local receive_operation = function(self, op)
      if self.accessing then
         error("Concurrent access to channel.")
      end
      self.accessing = true
      local future = new_future(ch, "data")
      local res = pack(future[op](future))
      self.accessing = false
      return unpack(res, 1, res.n)
   end
   
   return {
      send = function(_, ...)
         awake_future(ch, "data", ...)
      end,
      receive = receive_operation("get"),
      try_receive = receive_operation("try"),
   }
end

function async.io_popen(command, mode)
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
         awake_future(ch, "result", fd[op](fd, fd_cmd))
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
      lines = function()
         return nil, "Not available."
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
