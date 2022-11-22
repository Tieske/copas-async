# CHANGELOG

### Version x.x, unreleased

- Breaking: the os_execute return codes are no longer normalized to Lua 5.3 output
  Since that didn't work due to platform and version differences. Now it just returns
  the same results as the regular os.execute for this platform/Lua version.
- Fix: `io_popen`; the default mode should be "r"
- Fix: `io_popen`; the default read pattern should be "*l" and nil should not
  be passed.
- Fix: only initialize LuaLanes if not initialized already

### Version 0.3, released 4-Jul-2016

- Fix `unpack`

### Version 0.2, released 10-Jun-2016

- Added `io_popen`

### Version 0.1, released 2-Jun-2016

- Initial release
