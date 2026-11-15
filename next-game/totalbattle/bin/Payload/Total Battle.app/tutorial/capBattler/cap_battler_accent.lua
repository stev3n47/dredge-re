-- Easing wrappers: cc.Ease*(action) or cc.EaseElastic*(action, period)
--   Sine:       EaseSineIn / EaseSineOut / EaseSineInOut
--   Quadratic:  EaseQuadraticActionIn / ...Out / ...InOut
--   Cubic:      EaseCubicActionIn / ...Out / ...InOut
--   Quartic:    EaseQuarticActionIn / ...Out / ...InOut
--   Quintic:    EaseQuinticActionIn / ...Out / ...InOut
--   Exponential:EaseExponentialIn / ...Out / ...InOut
--   Circle:     EaseCircleActionIn / ...Out / ...InOut
--   Back:       EaseBackIn / EaseBackOut / EaseBackInOut       (overshoot)
--   Bounce:     EaseBounceIn / EaseBounceOut / EaseBounceInOut
--   Elastic:    EaseElasticIn / EaseElasticOut / EaseElasticInOut

local DIM_OPACITY = 100     -- прозрачность затемняющего оверлея (0–255)
local DIM_UI_TINT = 200     -- тинт UI-иконок остальных юнитов во время акцента (0–255, где 255 = норма)
local DOLLY_STRENGTH = 0.08 -- насколько камера приближается к юниту (доля расстояния)
local LIGHT_INTENSITY = 1.5 -- интенсивность accent-света во время акцента

-- Применяет fn(ui, duration) ко всем юнитам команды, кроме акцентированного
local function forTeamUI(ctx, ids, exceptId, fn, duration)
    for _, id in ipairs(ids) do
        if id ~= exceptId then
            local ui = ctx:getUnitBattleUI(id)
            if ui then fn(ui, duration) end
        end
    end
end

-- UI акцентированного юнита: скрывается на время акцента и возвращается обратно
local function playAccentUnitUI(ui, duration)
    local phaseIn   = duration * 0.15 -- *
    local phaseHold = duration * 0.70 -- *
    local phaseOut  = duration * 0.15 -- *
    ui:stopAllActions()
    ui:runAction(cc.Sequence:create(
        cc.FadeOut:create(phaseIn),
        cc.Hide:create(),
        cc.DelayTime:create(phaseHold),
        cc.Show:create(),
        cc.FadeIn:create(phaseOut)
    ))
end

-- UI союзников: приглушается тинтом и восстанавливается
local function playPlayerUnitUI(ui, duration)
    local phaseIn   = duration * 0.15 -- *
    local phaseHold = duration * 0.70 -- *
    local phaseOut  = duration * 0.15 -- *
    ui:stopAllActions()
    ui:runAction(cc.Sequence:create(
        cc.TintTo:create(phaseIn, DIM_UI_TINT, DIM_UI_TINT, DIM_UI_TINT),
        cc.DelayTime:create(phaseHold),
        cc.TintTo:create(phaseOut, 255, 255, 255)
    ))
end

-- UI врагов: приглушается тинтом и восстанавливается
local function playEnemyUnitUI(ui, duration)
    local phaseIn   = duration * 0.15 -- *
    local phaseHold = duration * 0.70 -- *
    local phaseOut  = duration * 0.15 -- *
    ui:stopAllActions()
    ui:runAction(cc.Sequence:create(
        cc.TintTo:create(phaseIn, DIM_UI_TINT, DIM_UI_TINT, DIM_UI_TINT),
        cc.DelayTime:create(phaseHold),
        cc.TintTo:create(phaseOut, 255, 255, 255)
    ))
end

-- Запускает UI-эффекты для всех трёх категорий: акцентированный юнит, союзники, враги
local function playUnitsUI(ctx, unitId, duration)
    local accentUI = ctx:getUnitBattleUI(unitId)
    if accentUI then playAccentUnitUI(accentUI, duration) end

    forTeamUI(ctx, ctx:getPlayerUnitIds(), unitId, playPlayerUnitUI, duration)
    forTeamUI(ctx, ctx:getEnemyUnitIds(), unitId, playEnemyUnitUI, duration)
end

-- Полупрозрачный оверлей поверх сцены: появляется и уходит вместе с акцентом
local function playDimOverlay(ctx, unitId, duration)
    local phaseIn   = duration * 0.15 -- *
    local phaseHold = duration * 0.70 -- *
    local phaseOut  = duration * 0.15 -- *

    ctx.dimOverlay:runAction(cc.Sequence:create(
        cc.FadeTo:create(phaseIn, DIM_OPACITY),
        cc.DelayTime:create(phaseHold),
        cc.FadeTo:create(phaseOut, 0),
        cc.CallFunc:create(function()
            ctx:setUnitAccented(unitId, false)
            ctx:finishAccent(unitId)
        end)
    ))
end

-- Дополнительный ambient-свет: включается в начале акцента и гасится после hold-фазы
local function playLight(ctx, duration)
    local light = ctx.accentLight
    if not light then return end

    local phaseIn   = duration * 0.15 -- *
    local phaseHold = duration * 0.70 -- *

    light:setIntensity(LIGHT_INTENSITY)
    light:runAction(cc.Sequence:create(
        cc.DelayTime:create(phaseIn + phaseHold),
        cc.CallFunc:create(function()
            light:setIntensity(0)
        end)
    ))
end

-- Dolly-движение камеры: плавно приближается к юниту и уходит обратно
local function playCamera(ctx, unitId, duration)
    local phaseIn   = duration * 0.15 -- *
    local phaseHold = duration * 0.70 -- *
    local phaseOut  = duration * 0.15 -- *

    local cam = ctx.cameraContainer
    local camPos = cam:getPosition3D()
    local unitPos = ctx:getUnitPosition(unitId)
    local delta = {
        x = (unitPos.x - camPos.x) * DOLLY_STRENGTH,
        y = (unitPos.y - camPos.y) * DOLLY_STRENGTH,
        z = (unitPos.z - camPos.z) * DOLLY_STRENGTH,
    }

    cam:stopAllActions()
    cam:runAction(cc.Sequence:create(
        cc.EaseSineOut:create(cc.MoveBy:create(phaseIn, delta)),
        cc.DelayTime:create(phaseHold),
        cc.EaseSineIn:create(cc.MoveBy:create(phaseOut, {x = -delta.x, y = -delta.y, z = -delta.z}))
    ))
end

-- Точка входа: запускает все эффекты акцента параллельно
function showAccent(ctx, unitId, duration)
    ctx:setUnitAccented(unitId, true)
    ctx:playUnitAccentFX(unitId) -- эффект задан в ultAccentFX в visualConfig.json

    playUnitsUI(ctx, unitId, duration)
    playDimOverlay(ctx, unitId, duration)
    playLight(ctx, duration)
    playCamera(ctx, unitId, duration)
end
