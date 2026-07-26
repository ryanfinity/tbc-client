-- QuestTracker v3.0
--
--  * Mob tooltips show your kill quests with live progress.
--  * Blizzard's 5-quest watch frame is REMOVED and replaced with our own tracker
--    panel: no quest cap, scales to its content, drag it by the cross on the
--    header, position + tracked quests persist per character.
--  * Shift-click quests in the quest log to add/remove them (Blizzard's own
--    modifier), and the quest log's checkmark ALWAYS matches the tracker.
--  * Double-click a quest in the tracker to open it in the quest log.
--
-- ---------------------------------------------------------------------------
-- WHY THE TRACKER OWNS THE LIST (measured, 2026-07-26 -- do not "simplify" this)
--
-- The obvious build is to let Blizzard's watch list be the single source of
-- truth and just render it. It cannot be: the client's C code hard-caps the
-- watch list at 5. Confirmed in game -- watching 9 quests via a direct
-- AddQuestWatch loop (which bypasses the Lua gate at QuestLogFrame.lua:509)
-- reported "9 tried, 5 watched", and no 6th checkmark could be made to appear.
-- Raising MAX_WATCHABLE_QUESTS only moves the Lua gate, not the C limit.
--
-- So OUR list is authoritative and we draw the quest log's checkmark ourselves
-- by post-hooking QuestLog_Update. That is safe because QuestLogFrame.lua is the
-- ONLY file in the whole 2.4.3 FrameXML that touches the quest-watch API --
-- nothing else reads IsQuestWatched, so nothing else can disagree with us.
--
-- v2.0 got this wrong and it caused the 1:1 bug: it post-hooked
-- QuestLogTitleButton_OnClick, so one shift-click ran BOTH Blizzard's toggle
-- (which set the checkmark) and ours (which toggled our list) -- in opposite
-- directions, because Blizzard's list is wiped on every relog while ours
-- persists. We now REPLACE that handler instead of hooking it, so exactly one
-- list changes per click.
--
-- ---------------------------------------------------------------------------
-- STYLE IS BLIZZARD'S, TAKEN FROM THE REAL FrameXML (extracted from the client
-- MPQs), not from taste:
--   font   : QuestWatchFontTemplate -> GameFontHighlight -> GameFontNormal
--            = Fonts\FRIZQT__.TTF at height 12, shadow 1/-1 black. Every line,
--            title and objective alike. (v2.0 used MORPHEUS -- that was the
--            "font looks off" report.)
--   layout : 13px per line, 4px extra gap before each new quest title.
--   colour : title    incomplete 0.75/0.61/0, complete 1/0.82/0
--            objective done 1/1/1 (white -- yes, BRIGHTER), todo 0.8/0.8/0.8
--   text   : " - " prefix on objectives, no level prefix on titles.
-- Colours are hardcoded rather than read from NORMAL_FONT_COLOR /
-- HIGHLIGHT_FONT_COLOR on purpose: those are not defined in FrameXML Lua, and a
-- nil global dereferenced at file scope is a LOAD-TIME error that kills the
-- entire addon. The numbers below are those globals' values, from Fonts.xml.
--
-- 2.4.3 notes: no print()/wipe(); script handlers use the implicit globals
-- (this/event/arg1); getglobal() instead of _G[].

QUESTTRACKER_VERSION = "3.0"

local function Msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuestTracker|r: " .. text)
end

QuestTrackerDB = QuestTrackerDB or {}

-- Blizzard's own measurements (QuestLogFrame.lua / Fonts.xml)
local FONT       = "Fonts\\FRIZQT__.TTF"
local FONT_SIZE  = 12
local LINE_STEP  = 13
local QUEST_GAP  = 4
local HEADER_Y   = -20      -- first quest title sits below the header line
local CROSS_SIZE = 16

local TITLE_TODO_R,  TITLE_TODO_G,  TITLE_TODO_B  = 0.75, 0.61, 0
local TITLE_DONE_R,  TITLE_DONE_G,  TITLE_DONE_B  = 1.0,  0.82, 0
local OBJ_DONE_R,    OBJ_DONE_G,    OBJ_DONE_B    = 1.0,  1.0,  1.0
local OBJ_TODO_R,    OBJ_TODO_G,    OBJ_TODO_B    = 0.8,  0.8,  0.8

local function ClassicFont(fs)
    fs:SetFont(FONT, FONT_SIZE)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
end

-- ===========================================================================
-- The watch list -- ordered quest IDs, the single source of truth
--
-- Keyed by quest ID, not title: titles are not unique, and v2.0's title keys
-- broke silently when a quest was renamed or duplicated. GetQuestLink is what
-- Blizzard itself uses for the shift-click chat link, so it is available for
-- any real quest log entry.
-- ===========================================================================
local seenThisSession = {}      -- questID -> true once observed in the log

local function QuestIDAt(index)
    local link = GetQuestLink(index)
    if not link then return nil end
    local _, _, id = string.find(link, "|Hquest:(%d+):")
    return tonumber(id)
end

local function Watched()
    QuestTrackerDB.watched = QuestTrackerDB.watched or {}
    return QuestTrackerDB.watched
end

local function TrackedAt(questID)
    if not questID then return nil end
    local list = Watched()
    for i = 1, table.getn(list) do
        if list[i] == questID then return i end
    end
    return nil
end

-- questID -> quest log index, for everything currently in the log
local function BuildIndexMap()
    local map = {}
    for entry = 1, GetNumQuestLogEntries() do
        local title, _, _, _, isHeader = GetQuestLogTitle(entry)
        if title and not isHeader then
            local id = QuestIDAt(entry)
            if id then
                map[id] = entry
                seenThisSession[id] = true
            end
        end
    end
    return map
end

local function IndexForQuestID(questID)
    if not questID then return nil end
    for entry = 1, GetNumQuestLogEntries() do
        local title, _, _, _, isHeader = GetQuestLogTitle(entry)
        if title and not isHeader and QuestIDAt(entry) == questID then
            return entry
        end
    end
    return nil
end

-- ===========================================================================
-- Tooltip: mob -> quest lines
-- ===========================================================================
local cache = {}
local dirty = true

local function RebuildCache()
    for k in pairs(cache) do cache[k] = nil end
    for entry = 1, GetNumQuestLogEntries() do
        local title, _, _, _, isHeader = GetQuestLogTitle(entry)
        if not isHeader and title then
            for obj = 1, GetNumQuestLeaderBoards(entry) do
                local text, objType, done = GetQuestLogLeaderBoard(obj, entry)
                if objType == "monster" and text then
                    local mob, have, need = string.match(text, "^(.-) slain: (%d+)/(%d+)$")
                    if not mob then
                        mob, have, need = string.match(text, "^(.-):%s*(%d+)/(%d+)$")
                    end
                    if mob and mob ~= "" then
                        cache[mob] = cache[mob] or {}
                        table.insert(cache[mob], {
                            title = title,
                            have = tonumber(have) or 0,
                            need = tonumber(need) or 0,
                            done = done and true or false,
                        })
                    end
                end
            end
        end
    end
    dirty = false
end

local lastAnnotated = nil
local function AnnotateTooltip(tooltip)
    if dirty then RebuildCache() end
    local name = tooltip:GetUnit()
    if not name or name == lastAnnotated then return end
    lastAnnotated = name
    local list = cache[name]
    if not list then return end
    for _, o in ipairs(list) do
        if o.done or (o.need > 0 and o.have >= o.need) then
            tooltip:AddLine(o.title .. " (" .. COMPLETE .. ")", 0.6, 0.6, 0.6)
        else
            tooltip:AddLine(o.title .. " - " .. o.have .. "/" .. o.need, 1.0, 0.82, 0.0)
        end
    end
    tooltip:Show()
end

if GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function() AnnotateTooltip(GameTooltip) end)
end
hooksecurefunc(GameTooltip, "SetUnit", function() AnnotateTooltip(GameTooltip) end)
GameTooltip:HookScript("OnHide", function() lastAnnotated = nil end)

-- ===========================================================================
-- Custom tracker panel (replaces QuestWatchFrame)
-- ===========================================================================

-- bury the Blizzard watch frame for good
QuestWatchFrame:UnregisterAllEvents()
QuestWatchFrame:Hide()
hooksecurefunc("QuestWatch_Update", function() QuestWatchFrame:Hide() end)

local panel = CreateFrame("Frame", "QuestTrackerFrame", UIParent)
panel:SetWidth(220)
panel:SetHeight(40)
panel:SetMovable(true)
panel:SetClampedToScreen(true)
-- The panel body takes NO mouse input: it is content-sized and used to swallow
-- every click over that whole area of the screen. Only the drag cross and the
-- per-quest click frames are interactive.
panel:EnableMouse(false)

-- Sit far-right, but clear the two right action bars (Interface > Action Bars:
-- "Right Bar" = MultiBarRight, "Right Bar 2" = MultiBarLeft). Only whichever are
-- actually shown push us further in, so the quest text is never hidden behind them.
local function RightBarInset()
    local inset = 30
    if MultiBarRight and MultiBarRight:IsShown() then
        inset = inset + (MultiBarRight:GetWidth() or 40)
    end
    if MultiBarLeft and MultiBarLeft:IsShown() then
        inset = inset + (MultiBarLeft:GetWidth() or 40)
    end
    return inset
end

local function ApplyDefaultAnchor()
    panel:ClearAllPoints()
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -RightBarInset(), -250)
end

-- The panel is ALWAYS anchored by its top-right corner, wherever it was dragged
-- to. That is what pins the header while the list grows downward: the panel is
-- resized to fit its content, so an anchor that is not a TOP* point makes
-- SetHeight expand upward as well -- the "grows in both directions" report.
-- StopMovingOrSizing does not guarantee it leaves a TOP* point behind, so we
-- never store what it produced; we store absolute edges and re-anchor ourselves.
-- Right-anchoring also matches Blizzard's own QuestWatchFrame and holds the drag
-- cross still while the width changes.
local function AnchorTopRight(right, top)
    panel:ClearAllPoints()
    panel:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right, top)
end

local function SavePosition()
    local right, top = panel:GetRight(), panel:GetTop()
    if not (right and top) then return false end
    QuestTrackerDB.pos = { right = right, top = top }
    AnchorTopRight(right, top)
    return true
end

local normalisePending = false
local function ApplyStoredPosition()
    local p = QuestTrackerDB.pos
    if p and p.right and p.top then
        AnchorTopRight(p.right, p.top)
    elseif p and p.point then
        -- v3.0 stored whatever StopMovingOrSizing left behind. Apply it once so
        -- the tracker does not jump, then convert to edges on the next layout.
        panel:ClearAllPoints()
        panel:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
        normalisePending = true
    else
        ApplyDefaultAnchor()
    end
end

local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
header:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
ClassicFont(header)
header:SetText("Quest Tracker")
header:SetTextColor(TITLE_TODO_R, TITLE_TODO_G, TITLE_TODO_B)

-- The drag handle. Built from a core texture Blizzard itself uses for the quest
-- log's collapsed headers, so it is guaranteed to exist in 2.4.3.
local cross = CreateFrame("Button", "QuestTrackerDragCross", panel)
cross:SetWidth(CROSS_SIZE)
cross:SetHeight(CROSS_SIZE)
cross:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 2)
cross:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
cross:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
cross:EnableMouse(true)
cross:RegisterForDrag("LeftButton")
cross:SetScript("OnDragStart", function()
    if not QuestTrackerDB.locked then panel:StartMoving() end
end)
cross:SetScript("OnDragStop", function()
    panel:StopMovingOrSizing()
    SavePosition()
end)
cross:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("Quest Tracker", 1, 1, 1)
    GameTooltip:AddLine("Drag here to move the tracker.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Double-click a quest to open it in your quest log.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
cross:SetScript("OnLeave", function() GameTooltip:Hide() end)

local lines = {}    -- FontString pool
local function GetLine(i)
    if not lines[i] then
        lines[i] = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lines[i]:SetJustifyH("LEFT")
        ClassicFont(lines[i])
    end
    return lines[i]
end

-- ===========================================================================
-- Opening a quest in the log
-- ===========================================================================
-- Selecting is deferred through pendingOpen rather than done inline, because
-- ExpandQuestHeader is not guaranteed to be reflected in GetQuestLogTitle before
-- the next QUEST_LOG_UPDATE -- Blizzard's own QuestLog_SetSelection expands and
-- then bails out, waiting for that event. Resolving by quest ID on each attempt
-- means a stale view can only delay the jump, never send it to the wrong quest.
local pendingOpen, pendingUntil = nil, 0

local function TryOpenPending()
    if not pendingOpen then return end
    local index = IndexForQuestID(pendingOpen)
    if not index then
        if GetTime() > pendingUntil then
            pendingOpen = nil
            Msg("that quest is no longer in your log.")
        end
        return
    end
    pendingOpen = nil
    QuestLogListScrollFrameScrollBar:SetValue((index - 1) * (QUESTLOG_QUEST_HEIGHT or 16))
    QuestLog_SetSelection(index)
    QuestLog_Update()
end

local function OpenQuestInLog(questID)
    if not questID then return end
    ShowUIPanel(QuestLogFrame)
    -- Only disturb the player's collapse state when the quest is actually hidden
    -- inside a collapsed header.
    if not IndexForQuestID(questID) then
        ExpandQuestHeader(0)
    end
    pendingOpen  = questID
    pendingUntil = GetTime() + 2
    TryOpenPending()
end

-- One invisible click frame per tracked quest, covering its title + objectives.
--
-- Double-click is detected by hand rather than with OnDoubleClick. The handler
-- does exist in 2.4.3 (it is in UI.xsd), but a manual GetTime() comparison has
-- no dependency on how it interacts with OnClick, and a single click must stay
-- inert either way.
local DOUBLE_CLICK_WINDOW = 0.4
local blocks = {}
local function GetBlock(i)
    if not blocks[i] then
        local b = CreateFrame("Button", nil, panel)
        b:RegisterForClicks("LeftButtonUp")
        b:SetScript("OnClick", function()
            local now = GetTime()
            if this.lastClick and (now - this.lastClick) < DOUBLE_CLICK_WINDOW then
                this.lastClick = nil
                OpenQuestInLog(this.questID)
            else
                this.lastClick = now
            end
        end)
        blocks[i] = b
    end
    return blocks[i]
end

local function RefreshPanel()
    local list = Watched()
    local map = BuildIndexMap()
    local logLoaded = GetNumQuestLogEntries() > 0

    -- Drop quests we watched and have since turned in or abandoned. Gated on
    -- "seen this session" so a not-yet-populated log at login cannot wipe the
    -- saved list.
    local i = 1
    while i <= table.getn(list) do
        local id = list[i]
        if not map[id] and logLoaded and seenThisSession[id] then
            table.remove(list, i)
        else
            i = i + 1
        end
    end

    local lineNum, blockNum = 0, 0
    local maxWidth = header:GetStringWidth() + CROSS_SIZE + 6
    local y = HEADER_Y

    for w = 1, table.getn(list) do
        local entry = map[list[w]]
        if entry then
            local title, _, _, _, _, _, isComplete = GetQuestLogTitle(entry)
            local blockTop = y

            lineNum = lineNum + 1
            local titleLine = GetLine(lineNum)
            titleLine:ClearAllPoints()
            titleLine:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
            if isComplete and isComplete > 0 then
                titleLine:SetText(title .. " (" .. COMPLETE .. ")")
                titleLine:SetTextColor(TITLE_DONE_R, TITLE_DONE_G, TITLE_DONE_B)
            elseif isComplete and isComplete < 0 then
                titleLine:SetText(title .. " (" .. FAILED .. ")")
                titleLine:SetTextColor(TITLE_TODO_R, TITLE_TODO_G, TITLE_TODO_B)
            else
                titleLine:SetText(title)
                titleLine:SetTextColor(TITLE_TODO_R, TITLE_TODO_G, TITLE_TODO_B)
            end
            titleLine:Show()
            if titleLine:GetStringWidth() > maxWidth then maxWidth = titleLine:GetStringWidth() end
            y = y - LINE_STEP

            for obj = 1, GetNumQuestLeaderBoards(entry) do
                local text, _, done = GetQuestLogLeaderBoard(obj, entry)
                if text then
                    lineNum = lineNum + 1
                    local objLine = GetLine(lineNum)
                    objLine:ClearAllPoints()
                    objLine:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, y)
                    objLine:SetText(" - " .. text)
                    if done then
                        objLine:SetTextColor(OBJ_DONE_R, OBJ_DONE_G, OBJ_DONE_B)
                    else
                        objLine:SetTextColor(OBJ_TODO_R, OBJ_TODO_G, OBJ_TODO_B)
                    end
                    objLine:Show()
                    if objLine:GetStringWidth() + 10 > maxWidth then
                        maxWidth = objLine:GetStringWidth() + 10
                    end
                    y = y - LINE_STEP
                end
            end

            blockNum = blockNum + 1
            local block = GetBlock(blockNum)
            block.questID = list[w]
            block.lastClick = nil
            block:ClearAllPoints()
            block:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, blockTop)
            block:SetHeight(blockTop - y)
            block:Show()

            y = y - QUEST_GAP
        end
    end

    for n = lineNum + 1, table.getn(lines) do lines[n]:Hide() end
    for n = blockNum + 1, table.getn(blocks) do blocks[n]:Hide() end

    -- scale the panel to its content
    local width = maxWidth + 4
    if width < 100 then width = 100 end
    panel:SetWidth(width)
    panel:SetHeight(-y + 4)
    for n = 1, blockNum do blocks[n]:SetWidth(width) end

    -- Re-anchor AFTER resizing, so the stored top/right edges are the ones that
    -- survive: the panel keeps its top line exactly where it was and the new
    -- content extends downward.
    if normalisePending then
        if SavePosition() then normalisePending = false end
    elseif not QuestTrackerDB.pos then
        -- Never dragged: keep the auto-position clearing whichever right action bars
        -- are live (picks up bar on/off changes on the next quest update).
        ApplyDefaultAnchor()
    end
end

-- ===========================================================================
-- Quest log integration -- the 1:1 half
-- ===========================================================================

-- We own the checkmark. Blizzard's QuestLog_Update has already shown or hidden
-- each row's Check from ITS list by the time we run, so we set every visible row
-- explicitly -- show AND hide -- and its list becomes irrelevant. The anchor
-- maths below is Blizzard's own, copied from QuestLogFrame.lua:216-238 so a
-- tracked quest's tick lands exactly where a stock one would.
local function DrawChecks()
    local offset = FauxScrollFrame_GetOffset(QuestLogListScrollFrame)
    for i = 1, (QUESTS_DISPLAYED or 6) do
        local check = getglobal("QuestLogTitle" .. i .. "Check")
        if check then
            local questIndex = i + offset
            local title, _, _, _, isHeader = GetQuestLogTitle(questIndex)
            local id = nil
            if title and not isHeader then id = QuestIDAt(questIndex) end

            if not TrackedAt(id) then
                check:Hide()
            else
                local questLogTitle  = getglobal("QuestLogTitle" .. i)
                local questTitleTag  = getglobal("QuestLogTitle" .. i .. "Tag")
                local questNormalText = getglobal("QuestLogTitle" .. i .. "NormalText")
                if not (questLogTitle and questTitleTag and questNormalText) then
                    -- verified present in 2.4.3's QuestLogFrame.xml; guarded only so a
                    -- surprise here cannot spam an error on every quest log redraw
                    check:Hide()
                    return
                end
                local tagText = questTitleTag:GetText()
                if tagText and tagText ~= "" then
                    local tempWidth = 275 - 15 - questTitleTag:GetWidth()
                    QuestLogDummyText:SetText("  " .. title)
                    local textWidth = QuestLogDummyText:GetWidth()
                    if textWidth > tempWidth then textWidth = tempWidth end
                    if questNormalText:GetWidth() + 24 < 275 then
                        check:SetPoint("LEFT", questLogTitle, "LEFT", textWidth + 24, 0)
                    else
                        check:SetPoint("LEFT", questLogTitle, "LEFT", textWidth + 10, 0)
                    end
                else
                    if questNormalText:GetWidth() + 24 < 275 then
                        check:SetPoint("LEFT", questNormalText, "LEFT", questNormalText:GetWidth() + 24, 0)
                    else
                        check:SetPoint("LEFT", questNormalText, "LEFT", questNormalText:GetWidth() - 10, 0)
                    end
                end
                check:Show()
            end
        end
    end
end
hooksecurefunc("QuestLog_Update", DrawChecks)

local function ToggleTracked(questIndex)
    local id = QuestIDAt(questIndex)
    if not id then return end
    local at = TrackedAt(id)
    if at then
        table.remove(Watched(), at)
    else
        if GetNumQuestLeaderBoards(questIndex) == 0 then
            UIErrorsFrame:AddMessage(QUEST_WATCH_NO_OBJECTIVES, 1.0, 0.1, 0.1, 1.0)
            return
        end
        table.insert(Watched(), id)
    end
    RefreshPanel()
end

-- REPLACED, not hooked. A post-hook would run in addition to Blizzard's own
-- watch toggle, which is exactly the desync this version exists to fix. This is
-- Blizzard's QuestLogFrame.lua:484 verbatim -- including falling through to
-- select the quest after a shift-click -- except that the QUESTWATCHTOGGLE
-- branch drives our list, and the 5-quest cap error is gone with it.
function QuestLogTitleButton_OnClick(button)
    local questIndex = this:GetID() + FauxScrollFrame_GetOffset(QuestLogListScrollFrame)
    if IsModifiedClick() then
        if this.isHeader then return end
        if IsModifiedClick("CHATLINK") and ChatFrameEditBox:IsVisible() then
            local questLink = GetQuestLink(questIndex)
            if questLink then ChatEdit_InsertLink(questLink) end
        elseif IsModifiedClick("QUESTWATCHTOGGLE") then
            ToggleTracked(questIndex)
        end
    end
    QuestLog_SetSelection(questIndex)
    QuestLog_Update()
end

-- ===========================================================================
-- Events / restore
--
-- Nothing has to be "re-applied" at login: the watch list is quest IDs, and
-- every refresh resolves IDs against the live log. That is also why the tracker
-- survives a relog when Blizzard's own list never does.
-- ===========================================================================
local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:SetScript("OnEvent", function()
    dirty = true
    if event == "PLAYER_ENTERING_WORLD" then
        ApplyStoredPosition()
    end
    RefreshPanel()
    TryOpenPending()
end)

ApplyStoredPosition()

-- /qt — status; /qt clear — untrack everything; /qt lock|unlock; /qt reset
SLASH_QUESTTRACKER1 = "/qt"
SlashCmdList["QUESTTRACKER"] = function(msg)
    local arg = string.lower(msg or "")

    if arg == "clear" then
        QuestTrackerDB.watched = {}
        RefreshPanel()
        QuestLog_Update()
        Msg("tracker cleared.")

    elseif arg == "lock" then
        QuestTrackerDB.locked = true
        Msg("tracker locked. /qt unlock to move it again.")

    elseif arg == "unlock" then
        QuestTrackerDB.locked = nil
        Msg("tracker unlocked — drag it by the cross on the header.")

    elseif arg == "reset" then
        QuestTrackerDB.pos = nil
        normalisePending = false
        ApplyDefaultAnchor()
        Msg("position reset.")

    else
        if dirty then RebuildCache() end
        local mobs = 0
        for _ in pairs(cache) do mobs = mobs + 1 end
        Msg(table.getn(Watched()) .. " quest(s) tracked, " .. mobs ..
            " mob name(s) on tooltip watch. Shift-click quests in the log to track them (no cap).")
        Msg("/qt clear | lock | unlock | reset")
    end
end

Msg("v" .. QUESTTRACKER_VERSION .. " loaded — shift-click quests in the log to track, " ..
    "double-click one here to open it, drag by the cross.")
