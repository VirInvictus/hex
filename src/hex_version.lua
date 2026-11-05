-- hex_version.lua: the Lua-side carrier of the single-source VERSION.
-- Kept in sync with the VERSION file at the repo root by the release flow
-- (tests/run.lua asserts the two agree; consumers: the GMCP core.hello and
-- the /hexupdate User-Agent).
return "0.5.2-dbg"
