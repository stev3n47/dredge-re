function showDamageTaken(ctx, unitId)
    local skel = ctx:getUnitSkeleton(unitId)
    if skel == nil then return end

    skel:runAction(cc.Sequence:create(
        cc.TintTo:create(0.1, 255, 0, 0),
        cc.TintTo:create(0.1,  255, 255, 255)
    ))
end
