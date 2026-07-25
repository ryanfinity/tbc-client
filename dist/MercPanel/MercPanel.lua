-- MercPanel v1.4 -- mercenary squad control bars
--
--  * Marker strip  (MercMarkerBar) : the 8 raid target icons + clear, docked under
--    the target frame. Left-click marks your target, right-click clears it.
--  * Command bar   (MercCmdBar)    : Stay / Follow / Come / Attack, the three
--    stances, and the Setup button.
--  * Timer bar     (MercTimerBar)  : reserve countdown / squad uptime. Needs a
--    persisted squad (innkeeper hire); mercs summoned with `.merc add` have none.
--  * Setup panel   (MercConfigPanel): per-squad behaviour sliders + recovery actions.
--
--  The marker + command bars appear ONLY while mercs are actually in your party;
--  the timer bar also shows for a RESERVED squad. "/merc pin" forces them visible
--  so you can place them with no mercs out. Each frame defaults to an anchor on the
--  TARGET FRAME and never to another frame, so dragging one never moves another.
--
--  Every frame drags independently (left-click drag) and remembers where you put
--  it, per character. "/merc reset" puts them all back.
--
--  Everything talks to the server as a plain ".merc ..." chat command -- the core
--  parses and swallows it in ChatHandler before any chat is broadcast, so nothing
--  leaks to other players. No server-side changes are needed for this addon.
--
--  2.4.3 notes: no print()/wipe(); script handlers use the implicit globals
--  (this / event / arg1); getglobal() instead of _G[].

MERCPANEL_VERSION = "1.4"

-- Transport. If dot-commands ever stop working over whisper, this is the ONE
-- line to change (e.g. to "SAY"). Whisper-to-self is used because an unhandled
-- command fails silently to you instead of broadcasting to the world.
local function MercCmd(cmd)
    if MercPanelDB and MercPanelDB.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Merc|r -> " .. cmd)
    end
    SendChatMessage(cmd, "WHISPER", nil, UnitName("player"))
end

local function Msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Merc|r: " .. text)
end

MercPanelDB = MercPanelDB or {}

-- ===========================================================================
-- Config definitions -- keys must match MercBotAI::LoadConfig
-- ===========================================================================
local CFG = {
    { key = "heal_threshold",       id = "Heal",  label = "Heal threshold",      min = 1, max = 100, def = 75,
      tip = "Healers start healing a party member below this % health." },
    { key = "emergency_threshold",  id = "Emerg", label = "Emergency threshold", min = 1, max = 100, def = 40,
      tip = "Below this % health healers drop everything and use their big fast heal." },
    { key = "leash_radius",         id = "Leash", label = "Leash radius (yd)",   min = 5, max = 100, def = 30,
      tip = "How far from you -- or from the Stay anchor -- mercs will chase a target." },
    { key = "shieldwall_threshold", id = "Wall",  label = "Shield Wall at %",    min = 1, max = 100, def = 20,
      tip = "The tank pops its big defensive cooldown below this % health." },
    { key = "pull_countdown",       id = "Pull",  label = "Pull countdown (s)",  min = 0, max = 10,  def = 3,
      tip = "Seconds the tank counts down in party chat before pulling a Skull." },
}

local MARKERS = {
    { idx = 1, name = "Star" },
    { idx = 2, name = "Circle",   note = "Rogue Blind target." },
    { idx = 3, name = "Diamond",  note = "Warlock: Seduce (humanoid) or Banish (demon/elemental)." },
    { idx = 4, name = "Triangle" },
    { idx = 5, name = "Moon",     note = "Mage Polymorph target." },
    { idx = 6, name = "Square" },
    { idx = 7, name = "Cross" },
    { idx = 8, name = "Skull",    note = "Tank pulls it, squad focus-fires it and never switches off." },
}

-- ===========================================================================
-- Small helpers
-- ===========================================================================
local function Skin(f)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
end

local function Tip(frame, title, body)
    frame.tipTitle = title
    frame.tipBody  = body
    frame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(this.tipTitle, 1, 1, 1)
        if this.tipBody then
            GameTooltip:AddLine(this.tipBody, 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function MakeDraggable(f, key)
    f:SetMovable(true)
    f:EnableMouse(true)
    -- keeps the frame inside UIParent even if a saved position came from a
    -- wider aspect ratio or a different UI scale
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if not MercPanelDB.locked then this:StartMoving() end
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, relPoint, x, y = this:GetPoint()
        MercPanelDB[key] = { point = point, relPoint = relPoint, x = x, y = y }
    end)
end

local function RestorePos(f, key, applyDefault)
    local p = MercPanelDB[key]
    f:ClearAllPoints()
    if p then
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        applyDefault(f)
    end
end

-- If a saved position came from a different aspect ratio / UI scale it can land
-- outside the visible area. Require at least a sliver of the frame on screen.
local function EnsureOnScreen(f, key, applyDefault)
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not l or not r or not t or not b then return end
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    if r < 30 or l > w - 30 or t < 30 or b > h - 30 then
        MercPanelDB[key] = nil
        f:ClearAllPoints()
        applyDefault(f)
        Msg("A bar was off-screen at this resolution -- moved back to its default spot.")
    end
end

local function Btn(parent, name, w, h, label, onClick)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(h)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

-- ===========================================================================
-- Marker strip
-- ===========================================================================
local markerBar = CreateFrame("Frame", "MercMarkerBar", UIParent)
markerBar:SetWidth(226)
markerBar:SetHeight(34)
markerBar:SetFrameStrata("MEDIUM")
Skin(markerBar)
MakeDraggable(markerBar, "markerPos")
markerBar:Hide()   -- shown by ApplyVisibility() once a squad is confirmed out

local function MarkerDefaultPos(f)
    -- Glued under the target frame. Nudged from the first pass (Ryan, in game):
    -- down ~1/4 of the bar height (34/4 ~ 8) and left ~1/2 an icon width (22/2 = 11).
    f:SetPoint("TOPLEFT", TargetFrame, "BOTTOMLEFT", 1, -10)
end

local function CanMark()
    if GetNumPartyMembers() > 0 and not IsPartyLeader() and not IsRaidLeader() then
        return false
    end
    return true
end

local function SetMark(index)
    if not UnitExists("target") then
        Msg("You need a target to mark.")
        return
    end
    if not CanMark() then
        Msg("Only the party leader can set raid markers.")
        return
    end
    SetRaidTarget("target", index)
end

for i = 1, 8 do
    local m = MARKERS[i]
    local b = CreateFrame("Button", "MercMarkerButton" .. i, markerBar)
    b:SetWidth(22)
    b:SetHeight(22)
    b:SetPoint("LEFT", markerBar, "LEFT", 7 + (i - 1) * 24, 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local col = (m.idx - 1) % 4
    local row = math.floor((m.idx - 1) / 4)
    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(b)
    tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    tex:SetTexCoord(col * 0.25, col * 0.25 + 0.25, row * 0.25, row * 0.25 + 0.25)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    b.markIndex = m.idx
    b:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            SetMark(0)
        else
            SetMark(this.markIndex)
        end
    end)

    local body = "Left-click to mark your target, right-click to clear."
    if m.note then body = m.note .. "\n\n" .. body end
    Tip(b, m.name, body)
end

local clearBtn = CreateFrame("Button", "MercMarkerClear", markerBar)
clearBtn:SetWidth(22)
clearBtn:SetHeight(22)
clearBtn:SetPoint("LEFT", markerBar, "LEFT", 7 + 8 * 24, 0)
clearBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
clearBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
clearBtn:SetScript("OnClick", function() SetMark(0) end)
Tip(clearBtn, "Clear mark", "Removes the raid marker from your target.")

-- ===========================================================================
-- Command bar
-- ===========================================================================
local cmdBar = CreateFrame("Frame", "MercCmdBar", UIParent)
cmdBar:SetWidth(246)
cmdBar:SetHeight(60)
cmdBar:SetFrameStrata("MEDIUM")
Skin(cmdBar)
MakeDraggable(cmdBar, "cmdPos")
cmdBar:Hide()   -- shown by ApplyVisibility() once a squad is confirmed out

-- Each bar anchors to the TARGET FRAME, never to another bar, so dragging one
-- never drags another. They only *look* stacked by default.
local function CmdDefaultPos(f)
    f:SetPoint("TOPLEFT", TargetFrame, "BOTTOMLEFT", 1, -46)
end

-- row 1: actions
local ACTIONS = {
    { label = "Stay",   cmd = ".merc stay",
      tip = "Hold this spot. The squad re-anchors its leash here and defends the anchor -- they do NOT go passive." },
    { label = "Follow", cmd = ".merc follow",
      tip = "Cancel Stay and follow you again." },
    { label = "Come",   cmd = ".merc come",
      tip = "Pull the squad to you if they get stuck or left behind." },
    { label = "Attack", cmd = ".merc attack",
      tip = "Focus your current target. Overrides the stance and the leash until the target dies or you Follow." },
}

for i = 1, 4 do
    local a = ACTIONS[i]
    local b = Btn(cmdBar, "MercAction" .. i, 57, 22, a.label, function() MercCmd(a.cmd) end)
    b:SetPoint("TOPLEFT", cmdBar, "TOPLEFT", 6 + (i - 1) * 58, -6)
    Tip(b, a.label, a.tip)
end

-- row 2: stances (radio) + setup
local STANCES = {
    { id = "passive",    label = "Passive",
      tip = "Hold fire. The squad disengages and will not attack anything." },
    { id = "defensive",  label = "Defensive",
      tip = "Default. Fight what attacks you or them, inside the leash." },
    { id = "aggressive", label = "Aggressive",
      tip = "Leash off. They engage anything hostile they can reach." },
}

local stanceButtons = {}

local function RefreshStance()
    local cur = MercPanelDB.stance or "defensive"
    for id, b in pairs(stanceButtons) do
        if id == cur then b:LockHighlight() else b:UnlockHighlight() end
    end
end

for i = 1, 3 do
    local s = STANCES[i]
    local b = Btn(cmdBar, "MercStance" .. i, 66, 22, s.label, function()
        MercPanelDB.stance = s.id
        MercCmd(".merc " .. s.id)
        RefreshStance()
    end)
    b:SetPoint("TOPLEFT", cmdBar, "TOPLEFT", 6 + (i - 1) * 67, -32)
    Tip(b, s.label .. " stance", s.tip)
    stanceButtons[s.id] = b
end

local setupBtn = Btn(cmdBar, "MercSetupButton", 32, 22, "Set", function()
    if MercConfigPanel:IsShown() then MercConfigPanel:Hide() else MercConfigPanel:Show() end
end)
setupBtn:SetPoint("TOPLEFT", cmdBar, "TOPLEFT", 208, -32)
Tip(setupBtn, "Setup", "Open the mercenary setup panel: behaviour sliders and recovery actions.")

-- ===========================================================================
-- Shared squad state + visibility
--
-- Declared here (not down in the timer section) because the setup panel's
-- server read-back needs to know whether a squad exists before it asks.
-- `channelBroken` is set only when a query gets NO reply at all, i.e. the addon
-- channel isn't reaching the server. Then we fail OPEN and show the bars anyway
-- -- better an unasked-for bar than no UI and no explanation.
-- ===========================================================================
local squad = { state = "NONE", members = 0, windowLeft = 0, uptime = 0,
                partyMercs = 0, channelBroken = false }

local function HasSquad()
    return squad.state == "ACTIVE" or squad.state == "RESERVED"
end

-- Gate on mercs ACTUALLY IN THE PARTY, not on the persisted squad: mercs summoned
-- with the GM `.merc add` command never create a merc_squad row, so squad state
-- would read NONE while four of them follow you around.
local function ApplyVisibility()
    local show = (not MercPanelDB.hidden)
                 and (MercPanelDB.pinned or squad.partyMercs > 0 or squad.channelBroken)
    if show then
        markerBar:Show()
        cmdBar:Show()
    else
        markerBar:Hide()
        cmdBar:Hide()
    end
end

-- ===========================================================================
-- Setup panel
-- ===========================================================================
local panel = CreateFrame("Frame", "MercConfigPanel", UIParent)
panel:SetWidth(260)
panel:SetHeight(452)
panel:SetFrameStrata("DIALOG")
Skin(panel)
MakeDraggable(panel, "panelPos")
panel:Hide()

local function PanelDefaultPos(f)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", panel, "TOP", 0, -12)
title:SetText("Mercenary Setup")

local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
sub:SetText("Applies to your whole squad")

local sliders = {}

local function SendCfg(entry, value)
    MercPanelDB.cfg = MercPanelDB.cfg or {}
    MercPanelDB.cfg[entry.key] = value
    MercCmd(".merc config mysquad " .. entry.key .. " " .. value)
end

for i = 1, table.getn(CFG) do
    local entry = CFG[i]
    local sname = "MercCfgSlider" .. entry.id
    local s = CreateFrame("Slider", sname, panel, "OptionsSliderTemplate")
    s:SetWidth(200)
    s:SetHeight(16)
    s:SetPoint("TOP", panel, "TOP", 0, -52 - (i - 1) * 44)
    s:SetMinMaxValues(entry.min, entry.max)
    s:SetValueStep(1)

    local start = entry.def
    if MercPanelDB.cfg and MercPanelDB.cfg[entry.key] then
        start = MercPanelDB.cfg[entry.key]
    end
    s:SetValue(start)

    getglobal(sname .. "Low"):SetText(entry.min)
    getglobal(sname .. "High"):SetText(entry.max)
    getglobal(sname .. "Text"):SetText(entry.label .. ":  " .. start)

    s.entry = entry
    s.sname = sname
    s:SetScript("OnValueChanged", function()
        local v = math.floor(this:GetValue() + 0.5)
        getglobal(this.sname .. "Text"):SetText(this.entry.label .. ":  " .. v)
    end)
    -- commit on release so dragging doesn't spam the server
    s:SetScript("OnMouseUp", function()
        SendCfg(this.entry, math.floor(this:GetValue() + 0.5))
    end)
    Tip(s, entry.label, entry.tip)

    sliders[i] = s
end

local resetCfg = Btn(panel, "MercCfgReset", 150, 22, "Reset to defaults", function()
    for i = 1, table.getn(CFG) do
        local entry = CFG[i]
        MercCmd(".merc config mysquad " .. entry.key .. " default")
        sliders[i]:SetValue(entry.def)
        if MercPanelDB.cfg then MercPanelDB.cfg[entry.key] = nil end
    end
    Msg("Behaviour settings reset to defaults.")
end)
resetCfg:SetPoint("TOP", panel, "TOP", 0, -52 - table.getn(CFG) * 44 + 6)
Tip(resetCfg, "Reset to defaults", "Clears every override so the squad falls back to the built-in behaviour.")

local recHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
recHeader:SetPoint("TOP", resetCfg, "BOTTOM", 0, -12)
recHeader:SetText("Recovery")

local RECOVERY = {
    { label = "Re-gear",  cmd = ".merc regear",
      tip = "Re-issue the squad's gear at your level. Use after a level-up or if a merc looks wrong." },
    { label = "Unstick",  cmd = ".merc fix mysquad",
      tip = "Reset every merc's brain and drop any wedged combat. The fix for 'they just stand there'." },
    { label = "Reconnect", cmd = ".merc recall",
      tip = "Bring an already-active squad back after a crash or a relog. 30 second cooldown. Does not replace hiring at an inn." },
    { label = "Release",  confirm = true,
      tip = "Dismiss the squad entirely. You will need to hire them again at an innkeeper." },
}

StaticPopupDialogs["MERCPANEL_RELEASE"] = {
    text = "Release your mercenary squad?\n\nThey will leave and you will need to hire them again at an innkeeper.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() MercCmd(".merc release") end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

for i = 1, 4 do
    local r = RECOVERY[i]
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local b = Btn(panel, "MercRecovery" .. i, 112, 22, r.label, function()
        if r.confirm then
            StaticPopup_Show("MERCPANEL_RELEASE")
        else
            MercCmd(r.cmd)
        end
    end)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", 14 + col * 118, -320 - row * 26)
    Tip(b, r.label, r.tip)
end

-- Lock the bars in place once they're where you want them.
--
-- Built from raw textures rather than UICheckButtonTemplate ON PURPOSE: the
-- template's auto-created "<name>Text" FontString is not guaranteed in 2.4.3, and
-- a nil getglobal() here is a LOAD-TIME error that kills the entire addon -- every
-- frame, the slash command, the lot. Core button textures always exist.
local lockCheck = CreateFrame("CheckButton", "MercCfgLock", panel)
lockCheck:SetWidth(24)
lockCheck:SetHeight(24)
lockCheck:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -378)
lockCheck:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
lockCheck:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
lockCheck:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
lockCheck:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

local lockLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
lockLabel:SetPoint("LEFT", lockCheck, "RIGHT", 4, 0)
lockLabel:SetText("Lock windows (stop dragging)")

lockCheck:SetScript("OnClick", function()
    MercPanelDB.locked = this:GetChecked() and true or nil
end)
Tip(lockCheck, "Lock windows",
    "Freeze the bars where they are so you can't drag them by accident. Your positions are saved per character either way.")

local closeBtn = Btn(panel, "MercCfgClose", 90, 22, "Close", function() panel:Hide() end)
closeBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 12)

-- ===========================================================================
-- Server read-back -- TrinityCore's addon-channel command protocol
--
--   request : "TrinityCore\t" .. 'i' .. counter(4) .. command
--   reply   : "TrinityCore\t" .. opcode .. counter(4) .. body
--             a = ack,  m = one output line,  o = done/ok,  f = failed
--
-- Implemented core-side by AddonChannelCommandHandler (Chat/Chat.cpp) -- this
-- needs no server changes. Replies arrive as CHAT_MSG_ADDON.
-- ===========================================================================
local ADDON_PREFIX = "TrinityCore"
local queryCounter = 0
local pending = {}

-- IMPORTANT ASYMMETRY, do not "fix" by adding the dot back:
--   chat          -> ChatHandler::ParseCommands  REQUIRES a leading '.' and strips it
--                    before calling _ParseCommands.
--   addon channel -> AddonChannelCommandHandler calls _ParseCommands DIRECTLY, so the
--                    command must arrive with NO leading dot.
-- Sending ".merc status" here makes the core hunt for a command named ".merc", miss,
-- and reply 'failed' -- which looks exactly like a dead channel.
local function MercQuery(cmd, onDone)
    queryCounter = (queryCounter + 1) % 10000
    local tag = string.format("%04d", queryCounter)
    local bare = string.gsub(cmd, "^%.", "")
    pending[tag] = { lines = {}, onDone = onDone, started = GetTime(), cmd = bare }
    SendAddonMessage(ADDON_PREFIX, "i" .. tag .. bare, "WHISPER", UnitName("player"))
    if MercPanelDB.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Merc|r >> [" .. tag .. "] " .. bare)
    end
end

local relay = CreateFrame("Frame")
relay.elapsed = 0
relay:RegisterEvent("CHAT_MSG_ADDON")
relay:SetScript("OnEvent", function()
    if arg1 ~= ADDON_PREFIX then return end
    local opcode = string.sub(arg2, 1, 1)
    local tag    = string.sub(arg2, 2, 5)
    local body   = string.sub(arg2, 6)
    local q = pending[tag]
    if not q then return end
    if MercPanelDB.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Merc|r << [" .. tag .. "] " .. opcode .. " " .. body)
    end
    if opcode == "m" then
        table.insert(q.lines, body)
    elseif opcode == "o" or opcode == "f" then
        pending[tag] = nil
        if q.onDone then
            q.onDone(q.lines, opcode == "o", opcode == "o" and "ok" or "failed")
        end
    end
end)
-- expire a query that never gets answered, so the panel says so instead of hanging
relay:SetScript("OnUpdate", function()
    this.elapsed = this.elapsed + arg1
    if this.elapsed < 1 then return end
    this.elapsed = 0
    local now = GetTime()
    for tag, q in pairs(pending) do
        if now - q.started > 5 then
            pending[tag] = nil
            -- no reply at all: the addon channel isn't reaching the server
            if q.onDone then q.onDone(q.lines, false, "timeout") end
        end
    end
end)

-- Pull the squad's REAL overrides off the server and drive the sliders from them.
-- ".merc config mysquad" prints "  <key> = <value>" per merc; a key the mercs
-- disagree on is shown as (mixed), a key nobody overrides as (default).
local function ShowDefaultSliders(note)
    for i = 1, table.getn(sliders) do
        local s = sliders[i]
        s:SetValue(s.entry.def)
        getglobal(s.sname .. "Text"):SetText(s.entry.label .. ":  " .. s.entry.def .. note)
    end
end

local function SyncFromServer()
    -- With no squad, ".merc config mysquad" legitimately fails server-side ("No
    -- mercenary named 'mysquad' belongs to your guild") because there is nothing to
    -- resolve. Don't call it and don't cry wolf -- that was the spurious
    -- "Couldn't read squad settings" on an empty party.
    if not HasSquad() then
        ShowDefaultSliders("  (default)")
        if squad.partyMercs > 0 then
            Msg("Your mercs were summoned by command, so there's no squad to tune as a group -- showing defaults. Hire at an innkeeper for per-squad settings.")
        else
            Msg("No squad out -- showing defaults. Hire mercs at an innkeeper, then reopen this to tune them.")
        end
        return
    end

    MercQuery(".merc config mysquad", function(lines, ok, reason)
        if not ok then
            if reason == "timeout" then
                Msg("No reply from the server on the addon channel -- showing last known values.")
            else
                Msg("The server couldn't read your squad settings -- showing last known values.")
            end
            return
        end
        local seen = {}
        for i = 1, table.getn(lines) do
            local _, _, k, v = string.find(lines[i], "^%s*([%a_][%w_]*)%s*=%s*(%d+)")
            if k and v then
                seen[k] = seen[k] or {}
                table.insert(seen[k], tonumber(v))
            end
        end
        for i = 1, table.getn(sliders) do
            local s = sliders[i]
            local vals = seen[s.entry.key]
            local v, suffix
            if not vals then
                v, suffix = s.entry.def, "  (default)"
            else
                v, suffix = vals[1], ""
                for j = 2, table.getn(vals) do
                    if vals[j] ~= vals[1] then suffix = "  (mixed)" end
                end
            end
            s:SetValue(v)   -- fires OnValueChanged, so set the label after
            getglobal(s.sname .. "Text"):SetText(s.entry.label .. ":  " .. v .. suffix)
        end
    end)
end

panel:SetScript("OnShow", function()
    lockCheck:SetChecked(MercPanelDB.locked)
    SyncFromServer()
end)

local refreshBtn = Btn(panel, "MercCfgRefresh", 90, 22, "Refresh", function() SyncFromServer() end)
refreshBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 12)
Tip(refreshBtn, "Refresh", "Re-read the squad's current settings from the server.")

-- ===========================================================================
-- Timer widget -- reserve countdown / squad uptime
--
-- Polls ".merc status" every 10s and ticks locally in between, so it reads like
-- a buff timer without hammering the server. Server reply (machine form):
--     MERCSTATUS <NONE|RESERVED|ACTIVE> <members> <windowLeftSec> <uptimeSec>
-- The countdown is the SAME number that auto-releases the squad -- both come off
-- merc_squad.reserved_at against the one summon-window constant.
-- ===========================================================================
local SUMMON_WINDOW = 1200   -- mirrors MERC_SUMMON_WINDOW_SEC (display scale only)
local POLL_PERIOD   = 10

local timerBar = CreateFrame("Frame", "MercTimerBar", UIParent)
timerBar:SetWidth(246)
timerBar:SetHeight(44)
timerBar:SetFrameStrata("MEDIUM")
Skin(timerBar)
MakeDraggable(timerBar, "timerPos")
timerBar:Hide()

local function TimerDefaultPos(f)
    f:SetPoint("TOPLEFT", TargetFrame, "BOTTOMLEFT", 1, -108)
end

local tIcon = timerBar:CreateTexture(nil, "ARTWORK")
tIcon:SetWidth(28)
tIcon:SetHeight(28)
tIcon:SetPoint("LEFT", timerBar, "LEFT", 9, 0)
tIcon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")

local tLabel = timerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tLabel:SetPoint("TOPLEFT", tIcon, "TOPRIGHT", 8, -2)

local tTime = timerBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tTime:SetPoint("TOPRIGHT", timerBar, "TOPRIGHT", -10, -8)

local tBar = CreateFrame("StatusBar", "MercTimerStatus", timerBar)
tBar:SetWidth(190)
tBar:SetHeight(9)
tBar:SetPoint("BOTTOMLEFT", tIcon, "BOTTOMRIGHT", 8, 1)
tBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
tBar:SetMinMaxValues(0, 1)
tBar:SetValue(1)

local function Clock(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor(sec / 60) % 60
    local s = sec % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", math.floor(sec / 60), s)
end

local function RenderTimer()
    ApplyVisibility()
    if MercPanelDB.hidden or squad.state == "NONE" then
        timerBar:Hide()
        return
    end
    timerBar:Show()

    if squad.state == "RESERVED" then
        tLabel:SetText("Summon your squad (" .. squad.members .. ")")
        tTime:SetText(Clock(squad.windowLeft))
        tBar:SetValue(squad.windowLeft / SUMMON_WINDOW)
        -- green -> amber -> red as the window closes
        if squad.windowLeft < 120 then
            tBar:SetStatusBarColor(0.9, 0.15, 0.15)
            tTime:SetTextColor(1, 0.3, 0.3)
        elseif squad.windowLeft < 300 then
            tBar:SetStatusBarColor(0.95, 0.7, 0.1)
            tTime:SetTextColor(1, 0.85, 0.4)
        else
            tBar:SetStatusBarColor(0.2, 0.75, 0.25)
            tTime:SetTextColor(1, 1, 1)
        end
    else
        tLabel:SetText("Squad out (" .. squad.members .. ")")
        tTime:SetText(Clock(squad.uptime))
        tTime:SetTextColor(1, 1, 1)
        tBar:SetValue(1)
        tBar:SetStatusBarColor(0.25, 0.5, 0.85)
    end
end

local function PollStatus()
    MercQuery(".merc status", function(lines, ok, reason)
        -- ".merc status" has no legitimate failure mode, so ANY failure here means we
        -- cannot determine whether mercs are out. Fail OPEN and say so -- silently
        -- returning is what made the missing dot look like "nothing is wrong".
        if not ok then
            if not squad.channelBroken then
                squad.channelBroken = true
                if reason == "timeout" then
                    Msg("No reply on the addon channel -- live timers are off and the bars will stay visible. Buttons still work.")
                else
                    Msg("The server rejected the status query -- live timers are off and the bars will stay visible. /merc debug shows the exchange.")
                end
                ApplyVisibility()
            end
            return
        end
        squad.channelBroken = false
        for i = 1, table.getn(lines) do
            local _, _, st, mem, win, up, party =
                string.find(lines[i], "^MERCSTATUS (%a+) (%d+) (%d+) (%d+) (%d+)")
            if st then
                squad.state      = st
                squad.members    = tonumber(mem)
                squad.windowLeft = tonumber(win)
                squad.uptime     = tonumber(up)
                squad.partyMercs = tonumber(party)
                RenderTimer()
            end
        end
    end)
end

-- one driver: 1s local tick for smooth motion, server poll every POLL_PERIOD
local ticker = CreateFrame("Frame")
ticker.tick = 0
ticker.poll = 0
ticker:SetScript("OnUpdate", function()
    this.tick = this.tick + arg1
    this.poll = this.poll + arg1

    if this.poll >= POLL_PERIOD then
        this.poll = 0
        PollStatus()
    end

    if this.tick < 1 then return end
    this.tick = 0
    if squad.state == "RESERVED" then
        squad.windowLeft = squad.windowLeft - 1
        if squad.windowLeft < 0 then squad.windowLeft = 0 end
        RenderTimer()
    elseif squad.state == "ACTIVE" then
        squad.uptime = squad.uptime + 1
        RenderTimer()
    end
end)

-- ===========================================================================
-- Slash command
-- ===========================================================================
SLASH_MERCPANEL1 = "/merc"
SLASH_MERCPANEL2 = "/mercpanel"
SlashCmdList["MERCPANEL"] = function(msg)
    local arg = string.lower(msg or "")

    if arg == "hide" then
        markerBar:Hide(); cmdBar:Hide(); panel:Hide(); timerBar:Hide()
        MercPanelDB.hidden = true
        Msg("Bars hidden. /merc show to bring them back.")

    elseif arg == "show" then
        MercPanelDB.hidden = nil
        RenderTimer()
        PollStatus()
        Msg("Bars re-enabled (they appear when your mercs are out).")

    elseif arg == "status" then
        PollStatus()
        MercCmd(".merc status")

    elseif arg == "pin" then
        MercPanelDB.pinned = not MercPanelDB.pinned
        ApplyVisibility()
        if MercPanelDB.pinned then
            Msg("Bars pinned visible (for placing them without mercs out). /merc pin again to release.")
        else
            Msg("Bars unpinned -- they now show only while your mercs are out.")
        end

    elseif arg == "reset" then
        MercPanelDB.markerPos = nil
        MercPanelDB.cmdPos    = nil
        MercPanelDB.panelPos  = nil
        MercPanelDB.timerPos  = nil
        RestorePos(markerBar, "markerPos", MarkerDefaultPos)
        RestorePos(cmdBar,    "cmdPos",    CmdDefaultPos)
        RestorePos(panel,     "panelPos",  PanelDefaultPos)
        RestorePos(timerBar,  "timerPos",  TimerDefaultPos)
        Msg("Positions reset.")

    elseif arg == "lock" then
        MercPanelDB.locked = true
        Msg("Bars locked. /merc unlock to move them.")

    elseif arg == "unlock" then
        MercPanelDB.locked = nil
        Msg("Bars unlocked -- drag them where you want.")

    elseif string.sub(arg, 1, 5) == "scale" then
        local n = tonumber(string.sub(arg, 7))
        if n and n >= 0.5 and n <= 2.0 then
            MercPanelDB.scale = n
            markerBar:SetScale(n)
            cmdBar:SetScale(n)
            panel:SetScale(n)
            timerBar:SetScale(n)
            Msg("Bar scale set to " .. n .. ".")
        else
            Msg("Usage: /merc scale 0.5 - 2.0   (current: " .. (MercPanelDB.scale or 1) .. ")")
        end

    elseif arg == "quiet" then
        MercPanelDB.quiet = not MercPanelDB.quiet
        Msg("Login message " .. (MercPanelDB.quiet and "off" or "on") .. ".")

    elseif arg == "debug" then
        MercPanelDB.debug = not MercPanelDB.debug
        Msg("Command echo " .. (MercPanelDB.debug and "ON" or "OFF") .. ".")

    elseif arg == "config" or arg == "setup" then
        if panel:IsShown() then panel:Hide() else panel:Show() end

    else
        Msg("MercPanel v" .. MERCPANEL_VERSION .. " -- /merc setup | status | pin | show | hide | lock | unlock | reset | scale <n> | quiet | debug")
    end
end

-- ===========================================================================
-- Boot
-- ===========================================================================
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
    if MercPanelDB.scale then
        markerBar:SetScale(MercPanelDB.scale)
        cmdBar:SetScale(MercPanelDB.scale)
        panel:SetScale(MercPanelDB.scale)
        timerBar:SetScale(MercPanelDB.scale)
    end

    RestorePos(markerBar, "markerPos", MarkerDefaultPos)
    RestorePos(cmdBar,    "cmdPos",    CmdDefaultPos)
    RestorePos(panel,     "panelPos",  PanelDefaultPos)
    RestorePos(timerBar,  "timerPos",  TimerDefaultPos)

    EnsureOnScreen(markerBar, "markerPos", MarkerDefaultPos)
    EnsureOnScreen(cmdBar,    "cmdPos",    CmdDefaultPos)
    EnsureOnScreen(panel,     "panelPos",  PanelDefaultPos)
    EnsureOnScreen(timerBar,  "timerPos",  TimerDefaultPos)

    RefreshStance()
    ApplyVisibility()
    PollStatus()

    -- A load confirmation removes all ambiguity between "the addon is loaded and the
    -- bars are correctly hidden" and "a Lua error killed the addon at load". Those two
    -- look identical on screen, and telling them apart cost a whole test round.
    if not MercPanelDB.quiet then
        Msg("v" .. MERCPANEL_VERSION .. " loaded. Bars appear when your mercs are out -- "
            .. "/merc pin to force them, /merc quiet to silence this line.")
    end

    -- re-apply saved slider values (SavedVariables may land after this file ran)
    for i = 1, table.getn(sliders) do
        local s = sliders[i]
        local v = s.entry.def
        if MercPanelDB.cfg and MercPanelDB.cfg[s.entry.key] then
            v = MercPanelDB.cfg[s.entry.key]
        end
        s:SetValue(v)
        getglobal(s.sname .. "Text"):SetText(s.entry.label .. ":  " .. v)
    end

    if MercPanelDB.hidden then
        markerBar:Hide()
        cmdBar:Hide()
    end
end)
