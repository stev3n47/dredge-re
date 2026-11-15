RepeatableTutorial("watchtower_widget",
	cond.All:new(
		cond.Event:new("GO_TO_WATCHTOWER")
	),
	function()
		WaitTime(500)
		if (GetCurrentSceneType() == "city") then
			ShowCursor("#mainButton", 180)
			WaitClick()
			WaitTime(1500)
		end

		ShowCursor("#watchtowerEasyWidget", 270)
		WaitClick()
	end
)

Tutorial("watchtower_intro",
	cond.All:new(
		cond.Event:new("LEVEL_UP_AFTER_DEFEAT"),
		cond.ViewShown:new("WatchtowerEasyView")
	),
	function()
		WaitTime(300)
        ShowTooltip("searchButton", "client.watchtower.tutor.tooltip_find")
		Highlight("searchButton")
        WaitClick()
		ClearCursor()
		WaitCondition(cond.ViewShown:new("PoiView"))
		WaitTime(500)
        ShowTooltip("mapPermission.Button.Attack", "client.watchtower.poi.tutor.tooltip_attack", "BOTTOM_MIDDLE")
		Highlight("mapPermission.Button.Attack")
		WaitClick()
		WaitTime(500)
		ShowCursor("selectButton", 180, 270)
		WaitClick()
		WaitTime(200)
		ShowCursor("startButton", 180, 270)
		WaitClick()
		MarkFinished()
		WaitTime(2000)
        ShowTooltip("#processView/actionLayout/purpleButton", "client.watchtower.march.tutor.tooltip_speed_up")
		Highlight("#processView/actionLayout/purpleButton")
		WaitClick()
	end
)
