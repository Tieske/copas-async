# CHANGELOG

#### Releasing new versions

- create a release branch
- update the changelog below
- update version and copyright-years in `./LICENSE` and `./src/copas/async.lua`
  (in doc-comments header)
- create a new rockspec and update the version inside the new rockspec:<br/>
  `cp copas-async-scm-1.rockspec ./rockspecs/copas-async-X.Y.Z-1.rockspec`
- test: run `make test` and `make lint`
- clean and render the docs: run `make clean` and `make docs`
- commit the changes as `release X.Y.Z`
- push the commit, and create a release PR
- after merging tag the release commit with `vX.Y.Z`
- upload to LuaRocks:<br/>
  `luarocks upload ./rockspecs/copas-async-X.Y.Z-1.rockspec --api-key=ABCDEFGH`
- test the newly created rock:<br/>
  `luarocks install copas-async`


### Version 1.0.0, released 26-Jun-2023

- Breaking: the `os_execute` return codes are no longer normalized to Lua 5.3 output
  since that didn't work due to platform and version differences. Now it just returns
  the same results as the regular `os.execute` for the current platform/Lua version.
- Fix: `io_popen`; the default mode should be "r"
- Fix: `io_popen`; the default read pattern should be "*l" and nil should not
  be passed.
- Fix: only initialize LuaLanes if not initialized already
- Added: `io_popen` now also has the `lines` iterator (except for Puc Rio Lua 5.1
  where it will not work due to c-boundary issues)
- Added: `run` method, to simply run and wait for an async result while not blocking
  (this also is the default action when calling on the module table).

### Version 0.3, released 4-Jul-2016

- Fix `unpack`

### Version 0.2, released 10-Jun-2016

- Added `io_popen`

### Version 0.1, released 2-Jun-2016

- Initial release
