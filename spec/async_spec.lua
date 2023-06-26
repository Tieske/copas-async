local load = loadstring or load -- load is Lua 5.2+, loadstring is 5.1

local defTimeout = 20
local copastest = require "spec.copas-busted"

describe("copas-async", function()

   local copas, done, settimeout, async, socket

   before_each(function()
      copas, done, settimeout = copastest(defTimeout)
      async = require "copas.async"
      socket = require "socket"
   end)

   after_each(function()
      done()
   end)



   describe("futures:", function()

      it("waiting for future:get()", function()
         settimeout(5)
         local result = {}
         copas(function()
            local future = async.addthread(assert(load([[
               local socket = require "socket"
               socket.sleep(3)
               return "hello", "world"
            ]])))
            local starttime = socket.gettime()
            result.returned = { future:get() }
            result.duration = socket.gettime() - starttime
            done()
         end)
         assert.same({"hello", "world"}, result.returned)
         assert.near(3, 0.1, result.duration)
      end)


      it("calling future:get() after it's done", function()
         local result = {}
         copas(function()
            local future = async.addthread(assert(load([[
               return "hello", "world"
            ]])))
            copas.sleep(3)
            result = { future:get() }
            done()
         end)
         assert.same({"hello", "world"}, result)
      end)


      it("waiting for future:try()", function()
         local result = {}
         copas(function()
            local future = async.addthread(assert(load([[
               local socket = require "socket"
               socket.sleep(3)
               return "hello", "world"
            ]])))
            copas.sleep(0.5)
            for i = 1, 4 do
               result[#result+1] = { future:try() }
               copas.sleep(1)
            end
            done()
         end)
         assert.same({ {false}, {false}, {false}, {true, "hello", "world"}}, result)
      end)


      it("calling future:try() after it's done", function()
         local result = {}
         copas(function()
            local future = async.addthread(assert(load([[
               return "hello", "world"
            ]])))
            copas.sleep(3)
            result = { future:try() }
            done()
         end)
         assert.same({true, "hello", "world"}, result)
      end)


      it("concurrent access to future errors", function()
         local result = {}
         copas(function()
            local future = async.addthread(assert(load([[
               local socket = require "socket"
               socket.sleep(3)
               return "hello", "world"
            ]])))
            copas.addthread(function()
               result.success = { future:get() }
               done()
            end)
            copas.sleep(0.1) -- ensure the 'get' is in progress
            copas.addthread(function() -- test future:try
               result.try = { pcall(future.try, future) }
            end)
            copas.addthread(function() -- test future:get
               result.get = { pcall(future.get, future) }
            end)
         end)
         assert(result.get[2]:match("concurrent access to future"))
         assert(result.try[2]:match("concurrent access to future"))
         assert.same({"hello", "world"}, result.success)
      end)

   end) -- futures



   describe("os_execute:", function()

      it("returns the exit code on success", function()
         local r, t, c
         copas(function()
            r, t, c = async.os_execute("sleep 1")
            done()
         end)
         if _VERSION == "Lua 5.1" then
            assert(r == 0 or r == true, "expected the result code to be 0 or 'true'")
         else
            assert.same(true, r)
            assert.same("exit", t)
            assert.same(0, c)
         end
      end)


      it("returns the exit code on failure", function()
         local r, t, c
         copas(function()
            r, t, c = async.os_execute("sleep 1; exit 123")
            done()
         end)
         if _VERSION == "Lua 5.1" then
            assert.not_equal(0, r)
         else
            assert.same(nil, r)
            assert.same("exit", t)
            assert.same(123, c)
         end
      end)

   end) -- os_execute



   describe("io_popen", function()

      it("Read all at once", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; done")
            copas.sleep(1)
            result.read = { fd:read("*a") }
            result.exit = { fd:close() }
            done()
         end)
         if _VERSION == "Lua 5.1" then
            assert.same({ "1\n2\n3\n4\n" }, result.read)
            assert.is_true(result.exit[1])
         else
            assert.same({
               read = { "1\n2\n3\n4\n" },
               exit = { true, "exit", 0 },
            }, result)
         end
      end)


      it("Read line by line", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; done")
            result.read = {}
            for i = 1, 4 do
               result.read[i] = fd:read("*l")
            end
            result.exit = { fd:close() }
            done()
         end)
         if _VERSION == "Lua 5.1" then
            assert.same({ "1", "2", "3", "4" }, result.read)
            assert.is_true(result.exit[1])
         else
            assert.same({
               read = { "1", "2", "3", "4" },
               exit = { true, "exit", 0 },
            }, result)
         end
      end)


      if _VERSION == "Lua 5.1" and not jit then
         pending("Read using fd:lines(): not supported on PuC Rio Lua 5.1", function() end)
      else
         it("Read using fd:lines()", function()
            local result = {}
            copas(function()
               local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; done")
               result.read = {}
               for line in fd:lines() do
                  result.read[#result.read+1] = line
               end
               result.exit = { fd:close() }
               done()
            end)
            if _VERSION == "Lua 5.1" then
               assert.same({ "1", "2", "3", "4" }, result.read)
               assert.is_true(result.exit[1])
            else
               assert.same({
                  read = { "1", "2", "3", "4" },
                  exit = { true, "exit", 0 },
               }, result)
            end
         end)
      end

      it("closing while incomplete", function()
         local result = {}
         copas(function()
            local fd = async.io_popen("for x in 1 2 3 4 ; do echo $x; sleep 1; done")
            result.read = {}
            result.read[1] = fd:read("*l") -- read only 1 of the 4 lines
            result.exit = { fd:close() }
            -- this will result in a number of "broken pipe" messages
            -- and the close call will take several seconds until the
            -- entire command exited
            done()
         end)
         if _VERSION == "Lua 5.1" then
            assert.same({ "1" }, result.read)
            assert.is_true(result.exit[1])
         else
            assert.same({
               read = { "1" },
               exit = { true, "exit", 0 },
            }, result)
         end
      end)

   end) -- io_popen

end)
