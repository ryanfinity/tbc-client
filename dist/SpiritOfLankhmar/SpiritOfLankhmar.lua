--[[----------------------------------------------------------------------------
  Spirit of Lankhmar -- the buff tooltip that declares this realm's QoL rules.

  WHY THIS ADDON EXISTS
  The buff itself is real: spell 53100, defined server-side in
  world.spell_template_override and applied on login by spirit_of_lankhmar.cpp.
  Its name and fallback tooltip live in the CLIENT's Spell.dbc, shipped in
  patch-enGB-3.MPQ -- because buff names and tooltips are client-side and the
  server cannot send them.

  But a 25 MB MPQ is a terrible place to keep text that we expect to EDIT. The
  whole point of this buff (docs/ROADMAP.md 3d) is that it becomes the standard
  vehicle for server-wide QoL rules, so adding rule #4 next month must be cheap.
  This addon makes it cheap: it rewrites the tooltip at runtime, so a wording
  change is a normal addon publish (kilobytes, launcher auto-updates it) instead
  of re-cutting and re-distributing the patch archive.

  If the addon is missing, nothing breaks -- the buff still shows with the DBC
  text baked into the MPQ. This only ever makes the tooltip better.

  ⚠️ KEEP RULES IN STEP with scripts/dbc_add_spirit_of_lankhmar.py (the fallback
  text) and, more importantly, with what the engine actually does. A buff that
  lies about the rules is worse than no buff.

  2.4.3 notes: Lua 5.1, no `#` operator on tables in places, no print(), and
  getglobal() rather than _G[]. Buff tooltips come from GameTooltip:SetPlayerBuff
  (measured in the client's own BuffFrame.lua, not assumed).
------------------------------------------------------------------------------]]

local BUFF_NAME = "Spirit of Lankhmar"

-- The header line, in the same gold the client uses for a buff title.
local TITLE_R, TITLE_G, TITLE_B = 1.0, 0.82, 0.0
-- Rule lines, in the client's standard "positive effect" green.
local RULE_R, RULE_G, RULE_B = 0.1, 1.0, 0.1
-- The intro line, dimmer so the rules stand out.
local LEAD_R, LEAD_G, LEAD_B = 0.8, 0.8, 0.8

local LEAD = "The realm of Lankhmar favours you:"

-- One entry per live server-wide rule. Only add a line once the engine really
-- does it.
local RULES = {
    "Food and drink restore twice as fast.",
    "Blessings, Arcane Intellect, Power Word: Fortitude,",
    "Divine Spirit, Shadow Protection, Mark of the Wild",
    "and Thorns last 60 minutes.",
}

--[[--------------------------------------------------------------------------
  Rewrite the tooltip.

  Called AFTER the client has filled the tooltip, so the first line already holds
  the spell name from Spell.dbc -- which is how we identify our buff without
  guessing at buff indices or matching on an icon path that another spell could
  share.
----------------------------------------------------------------------------]]
local function Decorate()
    local title = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
    if title ~= BUFF_NAME then
        return
    end

    -- Replace rather than append: the DBC description is only the offline
    -- fallback, and showing both would print the rules twice.
    GameTooltip:ClearLines()
    GameTooltip:AddLine(BUFF_NAME, TITLE_R, TITLE_G, TITLE_B)
    GameTooltip:AddLine(LEAD, LEAD_R, LEAD_G, LEAD_B)
    for i = 1, table.getn(RULES) do
        GameTooltip:AddLine(RULES[i], RULE_R, RULE_G, RULE_B)
    end
    -- ClearLines/AddLine changes the content, so the frame must be told to
    -- resize itself or the box keeps the old (wrong) dimensions.
    GameTooltip:Show()
end

--[[--------------------------------------------------------------------------
  Chain the original method rather than using hooksecurefunc's (table, "name")
  form, whose availability in 2.4.3 we have not measured. Storing and calling the
  previous implementation is guaranteed to work on this client, and it composes:
  if something else has already wrapped SetPlayerBuff, its version still runs.
----------------------------------------------------------------------------]]
local originalSetPlayerBuff = GameTooltip.SetPlayerBuff

GameTooltip.SetPlayerBuff = function(self, buffIndex)
    originalSetPlayerBuff(self, buffIndex)
    Decorate()
end
