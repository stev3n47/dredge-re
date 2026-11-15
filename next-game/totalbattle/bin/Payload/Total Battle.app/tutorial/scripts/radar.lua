local function ShowCursorWhenAvailable(path, direction, offset, scale)
    for _ = 1, 20 do
        WaitTime(500)
        if ShowCursor(path, direction, offset, scale) then
            return true
        end
    end
    return false
end

local RadarChipState = { READY = 1, IN_PROGRESS = 2, FINISHED = 3 }

-- Radar v1 hands out KILL monsters at level 2, v2/v3 hand out BATTLER (minigame) ones instead.
local HAS_MONSTER_CHIP = "HasRadarChip(\"KILL\") || HasRadarChip(\"BATTLER\")"

local function HideMonsterChips()
    SendEvent("HIDE_RADAR_CHIPS", "KILL")
    SendEvent("HIDE_RADAR_CHIPS", "BATTLER")
end

Tutorial("RadarStart",
    cond.All:new(
        cond.UnlockUIActive:new("radar")
    ),
    function()
        WaitTime(200)
        StartDialog({ "npc_proscope", "client.radar.tutorial.start.dialog_1" })
        MarkFinished()
        WaitTime(50)
        ShowCursorOnTarget("#personalRadarMapView", 180)
        WaitClick()
    end
)

Tutorial("RadarFirstChip",
    cond.All:new(
        cond.ViewShown:new("Radar::RadarView")
    ),
    function()
        SendEvent("HIDE_RADAR_CHIPS")
        WaitTime(50)
        StartDialog({ "npc_proscope", "client.radar.tutorial.first_chip.dialog_1" }, true)
        SendEvent("SHOW_RADAR_CHIPS")
        MarkFinished()
        ShowCursorWhenAvailable("radarChipView_RESCUE", 180)
        WaitClick()

        WaitTime(100)
        ShowCursor("goChipButton", 180, 270)
        WaitClick()
        MarkFinished("RadarFirstChipShort")
    end
)

Tutorial("RadarFirstChipShort",
    cond.All:new(
        cond.ViewShown:new("Radar::RadarView"),
        cond.TutorialFinished:new("RadarFirstChip")
    ),
    function()
        ShowCursorWhenAvailable("radarChipView_RESCUE", 180)
        WaitClick()

        WaitTime(100)
        ShowCursor("goChipButton", 180, 270)
        WaitClick()
    end
)

Tutorial("RadarHideKillChip",
    cond.All:new(
        cond.Event:new("RADAR_CHIPS_UPDATED"),
        cond.CheckCondition:new(HAS_MONSTER_CHIP)
    ),
    function()
        HideMonsterChips()
    end
)

-- RADAR_CHIPS_UPDATED re-checks it when the monster chips land after the level-up window is closed.
-- Priority 1 keeps RadarHideKillChip, which fires on the same event, from clearing it mid-dialog.
Tutorial("RadarKillChip",
    cond.All:new(
        cond.Event:new("RADAR_LEVEL_UP_CLOSED"),
        cond.Event:new("RADAR_CHIPS_UPDATED"),
        cond.CheckCondition:new(HAS_MONSTER_CHIP)
    ),
    function()
        HideMonsterChips()
        WaitTime(500)
        if not GetCurrentViewName():find("Radar::RadarView", 1, true) then
            WaitCondition(cond.ViewShown:new("Radar::RadarView"))
            WaitTime(300)
        end
        StartDialog({ "npc_proscope", "client.radar.tutorial.kill_chip.dialog_1" }, true)
        SendEvent("SHOW_RADAR_CHIPS")
    end,
    1
)

Tutorial("RadarLegendaryChip",
    cond.All:new(
        cond.Event:new("RADAR_CHIPS_UPDATED"),
        cond.CheckCondition:new("HasLegendaryRadarChip()")
    ),
    function()
        SendEvent("HIDE_RADAR_CHIPS", "LEGENDARY")
        WaitTime(1050)
        if not GetCurrentViewName():find("Radar::RadarView", 1, true) then
            WaitCondition(cond.ViewShown:new("Radar::RadarView"))
            WaitTime(300)
        end
        StartDialog({ "npc_proscope", "client.radar.tutorial.legendary_chip.dialog_1" }, true)
        SendEvent("SHOW_RADAR_CHIPS")
    end
)

Tutorial("RadarClaimChipWidget",
    cond.All:new(
        cond.RadarUpdated:new(),
        cond.CheckCondition:new("HasFinishedRadarChip()")
    ),
    function()
        ShowCursor("radarWidget", 180)
        MarkFinished()
        WaitClick()
    end
)

Tutorial("RadarClaimChip",
    cond.All:new(
        cond.Event:new("RADAR_CHIPS_UPDATED"),
        cond.CheckCondition:new("HasFinishedRadarChip()")
    ),
    function()
        MarkFinished("RadarClaimChipWidget")
        ShowCursorWhenAvailable("chipsHolder/@" .. RadarChipState.FINISHED, 180)
        WaitClick()
        ClearCursor()
        WaitCondition(cond.ViewHidden:new("SimpleRewardView"));
        WaitTime(200)
        StartDialog({ "npc_proscope", "client.radar.tutorial.claim_chip_ending.dialog_1" }, true)
    end
)

Tutorial("RadarProcessChipKill",
    cond.All:new(
        cond.Event:new("GO_TO_RADAR_CHIP_KILL")
    ),
    function()
        WaitTime(50)
        ClearHelperCursor()
        HideGui(0)
        StartDialog({ "npc_proscope", "client.radar.tutorial.process_kill.dialog_1" }, true, true)
        ShowGui()
        MarkFinished()
        WaitCondition(cond.ViewShown:new("MarchSendMyArmyView"))
        WaitTime(200)
        ShowCursor("startButton", 180, 180)
        WaitClick()
    end
)

Tutorial("RadarProcessChipBattler",
    cond.All:new(
        cond.Event:new("GO_TO_RADAR_CHIP_BATTLER")
    ),
    function()
        -- No dialog: process_kill talks about sending a march, and a BATTLER chip starts a minigame.
        ClearHelperCursor()
        MarkFinished()
        if not GetCurrentViewName():find("ClientMapObjectWindowView", 1, true) then
            WaitCondition(cond.ViewShown:new("ClientMapObjectWindowView"))
        end
        WaitTime(200)
        ShowCursor("march", 180)
        WaitClick()
    end
)

Tutorial("RadarProcessLegendaryKill",
    cond.All:new(
        cond.Event:new("GO_TO_RADAR_CHIP_SOLO_KILL")
    ),
    function()
        WaitTime(50)
        ClearHelperCursor()
        HideGui(0)
        StartDialog({ "npc_proscope", "client.radar.tutorial.process_legendary_kill.dialog_1" }, true, true)
        ShowGui()
        MarkFinished()
        WaitCondition(cond.ViewShown:new("MarchSendMyArmyView"))
        WaitTime(100)
        if GetTextValue("casualtiesLabel/valueLabel"):find("100") then
            ShowTooltip("casualtiesLabelHeader", "client.radar.tutorial.casualties_tooltip", "TOP_MIDDLE", 15)
            Highlight("casualtiesLabel/valueLabel", "rectangle", { width = 15, height = 15 })
        end
        WaitAnyClick()
    end
)
