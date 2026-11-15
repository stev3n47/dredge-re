Tutorial("speedup_marsh",
    cond.All:new(
        cond.ViewShown:new("PoiView"),
        cond.TutorialFinished:new("follow_marsh")
    ),
    function()
        WaitTime(500)
        ShowCursor("attackButton")
        WaitClick()
        WaitTime(500)
        ShowCursor("selectButton", 180, 270)
        WaitClick()
        WaitTime(500)
        ShowCursor("startButton", 180, 270)
        WaitClick()
        WaitTime(2000)
        ShowCursor("processView/actionLayout/purpleButton")
        WaitClick()
        WaitTime(500)
        ShowCursor("greenButton")
        WaitClick()
        WaitTime(500)
        ShowCursor("leftButton")
        WaitClick()
        MarkFinished()
        WaitTime(1000)
        ShowCursor("#mainButton", 180)
        WaitClick()
    end
)

Tutorial("first_marsh",
    cond.All:new(
        cond.ViewShown:new("PoiView"),
        cond.TutorialFinished:new("watchtower")
    ),
    function()
        WaitTime(500)
        ShowCursor("attackButton")
        WaitClick()
        WaitTime(500)
        ShowCursor("selectButton", 180)
        WaitClick()
        WaitTime(500)
        ShowCursor("startButton", 180)
        WaitClick()
    end
)

Tutorial("follow_marsh",
    cond.All:new(
        cond.TutorialFinished:new("watchtower"),
        cond.MarchStarted:new()
    ),
    function()
        FollowMarch(15)
        MarkFinished()
        WaitTime(500)
        ShowCursor("#mainButton", 180)
        WaitClick()
    end
)
