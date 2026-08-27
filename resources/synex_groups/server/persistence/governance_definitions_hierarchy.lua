return function(Foundation)
local rejected = require('server.persistence.governance_shared')(Foundation).rejected
local MAXIMUM_HIERARCHY_DEPTH = 64

local function apply(tx, item, parentItem)
    local live = item.groupState.live
    local parentId = parentItem and parentItem.targetGroupId or nil
    local currentParentId = live and tonumber(live.parent_group_id) or nil
    if parentId == currentParentId then return true, nil end
    if parentId == nil then
        if live then
            if currentParentId ~= nil and tx.affected([[DELETE FROM
                `synex_group_hierarchy_edges` WHERE `child_group_id` = ?
                    AND `version` = ?]], { live.id, live.edge_version }) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The static group hierarchy changed during reconciliation.', true)
            end
            tx.query([[DELETE `path` FROM `synex_group_hierarchy_closure` AS `path`
                INNER JOIN `synex_group_hierarchy_closure` AS `ancestor`
                    ON `ancestor`.`ancestor_group_id` = `path`.`ancestor_group_id`
                    AND `ancestor`.`descendant_group_id` = ?
                INNER JOIN `synex_group_hierarchy_closure` AS `subtree`
                    ON `subtree`.`ancestor_group_id` = ?
                    AND `subtree`.`descendant_group_id` = `path`.`descendant_group_id`
                WHERE `ancestor`.`ancestor_group_id` <> ?]], { live.id, live.id, live.id })
        end
        return true, nil
    end
    local childId = item.targetGroupId
    if tx.one([[SELECT `ancestor_group_id` FROM `synex_group_hierarchy_closure`
        WHERE `ancestor_group_id` = ? AND `descendant_group_id` = ?]],
        { childId, parentId }) then
        return rejected('HIERARCHY_CYCLE',
            'The static group parent would create an organization cycle.')
    end
    local parentDepth = tx.one([[SELECT MAX(`depth`) AS `maximum_depth`
        FROM `synex_group_hierarchy_closure` WHERE `descendant_group_id` = ?]], { parentId })
    local subtreeDepth = tx.one([[SELECT MAX(`depth`) AS `maximum_depth`
        FROM `synex_group_hierarchy_closure` WHERE `ancestor_group_id` = ?]], { childId })
    if not parentDepth or not subtreeDepth
        or tonumber(parentDepth.maximum_depth) == nil
        or tonumber(subtreeDepth.maximum_depth) == nil then
        return rejected('HIERARCHY_INVALID',
            'The static group hierarchy closure is incomplete.')
    end
    if tonumber(parentDepth.maximum_depth) + tonumber(subtreeDepth.maximum_depth) + 1
        > MAXIMUM_HIERARCHY_DEPTH then
        return rejected('HIERARCHY_DEPTH_EXCEEDED',
            'The static group hierarchy exceeds its supported depth.')
    end
    tx.many([[SELECT `ancestor_group_id`, `descendant_group_id`, `depth`
        FROM `synex_group_hierarchy_closure`
        WHERE `descendant_group_id` = ? OR `ancestor_group_id` = ? FOR UPDATE]],
        { childId, childId })
    tx.query([[DELETE `path` FROM `synex_group_hierarchy_closure` AS `path`
        INNER JOIN `synex_group_hierarchy_closure` AS `ancestor`
            ON `ancestor`.`ancestor_group_id` = `path`.`ancestor_group_id`
            AND `ancestor`.`descendant_group_id` = ?
        INNER JOIN `synex_group_hierarchy_closure` AS `subtree`
            ON `subtree`.`ancestor_group_id` = ?
            AND `subtree`.`descendant_group_id` = `path`.`descendant_group_id`
        WHERE `ancestor`.`ancestor_group_id` <> ?]], { childId, childId, childId })
    local edgeChanged
    if currentParentId ~= nil then
        edgeChanged = tx.affected([[UPDATE `synex_group_hierarchy_edges`
            SET `parent_group_id` = ?, `created_by_ref` = NULL,
                `reason_code` = 'static_definition_applied', `version` = `version` + 1
            WHERE `child_group_id` = ? AND `version` = ?]],
            { parentId, childId, live.edge_version }) == 1
    else
        edgeChanged = tx.affected([[INSERT INTO `synex_group_hierarchy_edges`
            (`child_group_id`, `parent_group_id`, `created_by_ref`, `reason_code`, `version`)
            VALUES (?, ?, NULL, 'static_definition_applied', 1)]],
            { childId, parentId }) == 1
    end
    if not edgeChanged then
        return rejected('CONCURRENT_MODIFICATION',
            'The static group hierarchy changed during reconciliation.', true)
    end
    tx.query([[INSERT INTO `synex_group_hierarchy_closure`
        (`ancestor_group_id`, `descendant_group_id`, `depth`)
        SELECT `ancestor`.`ancestor_group_id`, `subtree`.`descendant_group_id`,
            `ancestor`.`depth` + `subtree`.`depth` + 1
        FROM `synex_group_hierarchy_closure` AS `ancestor`
        CROSS JOIN `synex_group_hierarchy_closure` AS `subtree`
        WHERE `ancestor`.`descendant_group_id` = ?
            AND `subtree`.`ancestor_group_id` = ?]], { parentId, childId })
    return true, nil
end

return { apply = apply }
end
