-- hex_chat.lua: chat capture and recall (design: docs/phase-6-social.md §1).
-- Taxonomy ported from tt_dw's misc/chat.tin: tells (in + own) highest, then
-- clubs, group, talkers, system shouts. Room say/souls are deliberately NOT
-- captured (tt_dw's decision: the channel is NPC-dominated).
--
-- The awareness rule (concepts/automation) is a UI constraint here: mirror
-- mode is the default, so chat NEVER leaves the main feed. With a blightmud
-- that has tabs (dev tree only; feature-detected), one `chat` tab mirrors via
-- Rust-side filters -- triggers capture/notify only, no output_to in the hot
-- path, no double-routing.
--
-- Talker shapes follow the official docs (leading dash, parenthesised
-- channel, `saying : `); club names are player-configurable so those
-- regexes stay wire-checkable (tonight's capture).
--
-- Pure: rings, exclusions, line classification (LUA patterns here; the
-- runtime triggers use the Rust forms of the same shapes). Runtime glue
-- owns triggers and the tab.
local util = require("src.hex_util")
local notify = require("src.hex_notify")

local M = {}

-- NPCs whose chat lines are not worth capturing (chat.tin:19-27, deduped;
-- the tt_dw pattern entries become suffix checks in is_npc).
M.NPCS = {
  "stephen jobbes", "sam slager", "mr werks", "frank", "sol", "shifty jim",
  "nella", "jonas", "thella", "free sitting birds", "nostos", "philip legrande",
  "will", "jack straw", "olivia", "noobie", "ryattenoki",
  "the animal rights protester", "cogsworth", "louise eanna", "velveta",
  "mr myrtle", "the aged teller", "shamir stonecutter", "talula", "buccaneer",
  "noelle ratson", "very reverend khepresh", "kess of sek", "william cobbler",
  "briony", "someone", "something",
}

M.NPC_SUFFIXES = {
  " city guard", " citadel guard", " watchman", " watchmen",
  " mean mercenary", " mean mercenaries", " musketeer",
  " old man", " delivery man", " buccaneer",
}

-- job-completion noise texts (chat.tin:29-41); tintin `.` = any char,
-- `..?` = 1-2 chars; tested case-insensitively with `"` -> `'` per :228.
-- Lua-pattern forms here; %c placeholder digits became explicit sets.
M.JOB_TEXTS = {
  "great, i've been waitin. for ..?is!",
  "many thanks, h?you've p?saved the day ..?or me!",
  "..?, that h?will do ni.ely! thank h?y..?.",
  "aha, h?y..?, ..?is is what i was after!",
  "thanks%. hope it wasn't too difficult to get h?your hands on%.",
  "thank h?you, but i am still waitin%. for .+",
  "thank h?you, that's everything i needed!",
  "excellent!  send my regards to mr werks%.",
  "that's the ticket!  just%.%.%. don't tell anyone, okay%?",
  "i'm sorry, but i didn't request delivery of .+",
  "i only needed .+ to complete my order%.  keep the remainder!",
  "awww, yeah!  i am off the hook tomorrow night!",
}

M.FAMILIES = { "tell", "club", "group", "talker", "system" }

-- ring caps (design §1.5): tt_dw's unbounded lists consciously dropped
M.CAPS = { tell = 150, group = 100, system = 100, talker = 200, club = 300, all = 500 }

M.rings = { tell = {}, club = {}, group = {}, talker = {}, system = {}, all = {} }

-- Rust capture regexes for the runtime triggers (design §1.2, official
-- talker shapes folded in). classify() mirrors these in Lua patterns.
M.PATTERNS = {
  tell = "^([\\w'][\\w' ]*) (?:says to|asks|tells|exclaims to|whispers to) .*?you(?: in \\w+)?: (.+)$",
  own = "^You (?:tell|ask|exclaim to|whisper to) (?!in )([\\w'][\\w' ]*): (.+)$",
  club = "^\\(([\\w' -]+)\\) ([\\w' ]+):? (.+)$",
  group = "^\\[([\\w'. -]+)\\] ([\\w' ]+):? (.+)$",
  talker = "^-? ?(?:\\(([^)]+)\\) )?([\\w' ]+)(?:'s wispy voice comes from .*,? saying ?| wisps):? ?(.+)$",
  system = "^Offler the Crocodile God shouts: (.+)$",
}

local TELL_VERBS = { "says to you", "asks you", "tells you", "exclaims to you", "whispers to you" }
local OWN_VERBS = { "tell", "ask", "exclaim to", "whisper to" }

-- --- pure core ---

function M.is_npc(name)
  local n = util.trim(tostring(name)):lower()
  for _, npc in ipairs(M.NPCS) do
    if n == npc then
      return true
    end
  end
  for _, suffix in ipairs(M.NPC_SUFFIXES) do
    if n:find(suffix, 1, true) then
      return true
    end
  end
  return false
end

function M.is_job_noise(text)
  local t = tostring(text):gsub('"', "'"):lower()
  for _, job in ipairs(M.JOB_TEXTS) do
    if t:find(job) then
      return true
    end
  end
  return false
end

-- Classify a line (Lua patterns, verb lists instead of alternation).
-- Order matters: incoming tell, own tell, club, group, talker, system.
-- Returns family, entry or nil.
function M.classify(line)
  local s = util.trim(tostring(line))
  local who, lang, text
  for _, verb in ipairs(TELL_VERBS) do
    who, lang, text = s:match("^([%w'][%w' ]*) " .. verb .. " in (%w+): (.+)$")
    if not who then
      who, text = s:match("^([%w'][%w' ]*) " .. verb .. ": (.+)$")
    end
    if who then
      if M.is_npc(who) or M.is_job_noise(text) then
        return nil
      end
      return "tell", { name = util.trim(who), text = text, language = lang }
    end
  end
  -- own-tell language broadcast: "You tell X in <Language>: ..." is the
  -- broadcast form, not a tell (tt_dw chat.tin:211's guard)
  if s:match("^You %a+ .+ in %w+: .+$") then
    return nil
  end
  local own_text
  for _, v in ipairs(OWN_VERBS) do
    local target
    target, own_text = s:match("^You " .. v .. " ([%w'][%w' ]*): (.+)$")
    if target then
      if target == "in" or target:match("^in ") then
        return nil -- "You tell X in <language> ...": a broadcast, not a tell
      end
      return "tell", { name = util.trim(target), text = own_text, own = true }
    end
  end
  -- talkers before clubs: the brief talker shape "(one) Feantur wisps: Ook!"
  -- would otherwise collide with the club pattern (tt_dw dodges this with
  -- its colour-prefix trick, which blightmud triggers cannot reproduce)
  local channel, tname, ttext = s:match("^%-? ?%(([^)]+)%) ([%w' ]+)'s wispy voice comes from .*,? saying ?:? ?(.+)$")
  if not channel then
    channel, tname, ttext = s:match("^%(([^)]+)%) ([%w' ]+) wisps: ?(.+)$")
  end
  if channel then
    if M.is_npc(tname) then
      return nil
    end
    return "talker", { channel = channel, name = util.trim(tname), text = ttext }
  end
  local club, cname, ctext = s:match("^%(([%w' %-]+)%) ([%w' ]+):? (.+)$")
  if club then
    if M.is_npc(cname) then
      return nil
    end
    return "club", { channel = club, name = util.trim(cname), text = ctext }
  end
  local group, gname, gtext = s:match("^%[([%w'%. %-]+)%] ([%w' ]+):? (.+)$")
  if group then
    if M.is_npc(gname) then
      return nil
    end
    return "group", { channel = group, name = util.trim(gname), text = gtext }
  end
  local shout = s:match("^Offler the Crocodile God shouts: (.+)$")
  if shout then
    return "system", { name = "Offler", text = shout }
  end
  return nil
end

function M.push(family, entry)
  local ring = M.rings[family]
  ring[#ring + 1] = { name = entry.name, text = entry.text, channel = entry.channel, t = os.time() }
  while #ring > (M.CAPS[family] or 100) do
    table.remove(ring, 1)
  end
  M.rings.all[#M.rings.all + 1] = { family = family, name = entry.name, text = entry.text, t = os.time() }
  while #M.rings.all > M.CAPS.all do
    table.remove(M.rings.all, 1)
  end
end

-- Capture pipeline: classify, filter, ring, notify. Called from the
-- runtime trigger with the raw line text.
function M.capture(line)
  local family, entry = M.classify(line)
  if not family then
    return nil
  end
  if not M.family_on(family) then
    return family
  end
  M.push(family, entry)
  if family == "tell" and not entry.own then
    notify.emit("chat.tell", entry)
  elseif family == "system" then
    notify.emit("chat.shout", entry)
  elseif family == "club" then
    notify.emit("chat.club", entry)
  elseif family == "group" then
    notify.emit("chat.group", entry)
  elseif family == "talker" then
    notify.emit("chat.talker", entry)
  end
  return family
end

-- --- runtime glue (blightmud globals below this line) ---

M.deps = {}
M.has_tabs = false

function M.setup(deps)
  M.deps = deps
  M.has_tabs = blight ~= nil and blight.create_tab ~= nil
end

function M.family_on(family)
  local families = M.deps.config.get("chat_families", { tell = true, club = true, group = true, talker = true, system = true })
  return families[family] ~= false
end

-- The tab's include filters, one per enabled family (design §1.4).
function M.tab_includes()
  local includes = {}
  for _, family in ipairs(M.FAMILIES) do
    if M.family_on(family) then
      includes[#includes + 1] = M.PATTERNS[family]
    end
  end
  return includes
end

-- NPC excludes as one (?i) alternation for the tab's exclude filter
-- (Rust side, so the suffix patterns keep their tt_dw alternation shapes).
M.TAB_EXCLUDE_ALTS = {
  ".+ cit(?:y|adel) guards?", ".+ watchm(?:a|e)n", ".+ mean mercenar(?:y|ies)",
  ".+ musketeer", ".+ (?:old|delivery) man", ".+ buccaneer",
}

function M.tab_excludes()
  local parts = {}
  for _, npc in ipairs(M.NPCS) do
    if not npc:find("%.") then
      parts[#parts + 1] = npc
    end
  end
  for _, alt in ipairs(M.TAB_EXCLUDE_ALTS) do
    parts[#parts + 1] = alt
  end
  return "(?i)^(" .. table.concat(parts, "|") .. ") "
end

-- Idempotent tab setup: create_tab raises on an existing name, so check
-- blight.tabs() first; binds overwrite, so set them unconditionally.
function M.setup_tab()
  if not M.has_tabs or not M.deps.config.get("chat_tab", true) then
    return
  end
  local existing = blight.tabs and blight.tabs() or {}
  for _, name in ipairs(existing) do
    if name == "chat" then
      return -- already there (e.g. after a reload); filters are append-only
    end
  end
  blight.create_tab("chat")
  for _, include in ipairs(M.tab_includes()) do
    blight.add_tab_filter("chat", include)
  end
  blight.add_tab_filter("chat", M.tab_excludes())
  if blight.bind then
    blight.bind("chat", "F2")
    blight.bind("main", "F1")
  end
end

function M.register(trigger_add, Regex)
  -- one trigger per family + own tells (mirror mode: no gag, no output_to);
  -- capture + notify only, the tab (if any) routes by its own filters
  local specs = {
    { M.PATTERNS.tell, true },
    { M.PATTERNS.own, false },
    { M.PATTERNS.club, false },
    { M.PATTERNS.group, false },
    { M.PATTERNS.talker, false },
    { M.PATTERNS.system, false },
  }
  for _, spec in ipairs(specs) do
    trigger_add(Regex.new(spec[1], spec[2] and { case_insensitive = true } or nil), {}, function(matches, line)
      M.capture(line)
      return line
    end)
  end
end

-- /chat [family] [n]: the greppable recall view.
local function color_for(family)
  return ({ tell = "magenta", club = "cyan", group = "yellow", talker = "green", system = "red" })[family]
end

function M.cmd_chat(args)
  local family, count = args:match("^(%a+)%s*(%d*)$")
  count = tonumber(count) or 20
  if family and not M.rings[family] then
    print(util.ansi.gray .. "usage: /chat [tell|club|group|talker|system] [n]" .. util.ansi.reset)
    return
  end
  local ring = family and M.rings[family] or M.rings.all
  if #ring == 0 then
    print(
      util.ansi.gray
        .. "[hex] nothing captured yet"
        .. (not M.has_tabs and " (no tab API in this blightmud; chat stays in the main feed)" or "")
        .. util.ansi.reset
    )
    return
  end
  local from = math.max(1, #ring - count + 1)
  for i = from, #ring do
    local e = ring[i]
    local line = ("[%s] %s"):format(os.date("%H:%M", e.t), e.name or "?")
    if e.channel then
      line = line .. " (" .. e.channel .. ")"
    end
    line = line .. " " .. e.text
    local wrapped = util.wrap(line, 78)
    for j, w in ipairs(wrapped) do
      local out = (j > 1 and "  " or "") .. w
      if family and j == 1 and color_for(family) then
        print(util.ansi[color_for(family)] .. out .. util.ansi.reset)
      else
        print(out)
      end
    end
  end
end

-- /chatset <family> on|off: config now; tab filter rebuild when the API
-- allows it (filters are append-only, so a rebuild needs tab removal).
function M.cmd_chatset(args)
  local family, state = args:match("^(%a+)%s+(on|off)$")
  if not family or not M.rings[family] then
    print(util.ansi.gray .. "usage: /chatset <tell|club|group|talker|system> <on|off>" .. util.ansi.reset)
    return
  end
  local families = M.deps.config.get("chat_families", { tell = true, club = true, group = true, talker = true, system = true })
  families[family] = state == "on"
  M.deps.config.set("chat_families", families)
  print(
    util.ansi.gray
      .. "[hex] chat family "
      .. family
      .. " "
      .. state
      .. (M.has_tabs and " (tab filters are append-only; restart blightmud to rebuild)" or "")
      .. util.ansi.reset
  )
end

return M
