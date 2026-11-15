Tutorial("expedition_intro",
    cond.All:new(
            cond.Event:new("EXPEDITION_OPENED")
    ),
    function()
        WaitTime(300)
        StartDialog({ "npc_aydae", "client.expedition.intro.dialog_01" })
        MarkFinished()
        WaitTime(200)
        ShowCursor("rewardEntryPoint/info", 180, 0, { x = 0, y = 0 })
        WaitClick()
        WaitTime(200)
        ShowTooltip("personalExpeditionRewardMilestoneView", "client.expedition.intro.tutor.tooltip_stage")
        Highlight("personalExpeditionRewardMilestoneView/bg")
        WaitAnyClick(false)
        ShowCursor("goActionButton", 180)
        WaitClick()
    end
)

Tutorial("expedition_dragon_intro",
    cond.All:new(
            cond.Event:new("EXPEDITION_DRAGON_OPENED")
    ),
    function()
        WaitTime(300)
        ClearHelperCursor()
        ShowCursor("rewardEntryPoint/info", 180, 0, { x = 0, y = 0 })
        WaitClick()
        MarkFinished()
        WaitTime(200)
        ShowTooltip("personalExpeditionRewardMilestoneView", "client_config.save_dragon.expedition_tooltip")
        Highlight("personalExpeditionRewardMilestoneView/bg")
        DismissVisualsOnAnyClick()
        WaitClick()
    end
)