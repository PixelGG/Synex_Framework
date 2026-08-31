local function consumer()
    local resource = GetInvokingResource()
    if type(resource) ~= 'string' or #resource < 2 or #resource > 64
        or not resource:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') then
        return nil
    end
    return resource
end

exports('GetPlayerData', function()
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_qbx:GetPlayerDataForConsumer(caller)
end)

exports('GetGroups', function()
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_qbx:GetGroupsForConsumer(caller)
end)
exports('Notify', function(text, notifyType, durationMs, subTitle,
    notifyPosition, notifyStyle, notifyIcon, notifyIconColor)
    local caller = consumer()
    if not caller then return nil end
    return exports.synex_bridge_qbx:NotifyForConsumer(caller, text, notifyType,
        durationMs, subTitle, notifyPosition, notifyStyle, notifyIcon,
        notifyIconColor)
end)
