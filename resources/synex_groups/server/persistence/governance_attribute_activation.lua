return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local AttributeValues = require('server.persistence.governance_attribute_values')(Foundation)
local ATTRIBUTE_TYPES = AttributeValues.ATTRIBUTE_TYPES
local publicId = Shared.publicId
local storedAttributeValue = AttributeValues.storedAttributeValue
local typedAttributeValue = AttributeValues.typedAttributeValue
local decodeStoredRules = AttributeValues.decodeStoredRules
local MAXIMUM_EFFECTIVE_SCHEMAS = 256

local function effectiveActivationSchemas(tx, membership)
    local organization = tx.one([[SELECT group_type_id
        FROM synex_group_organization_profiles
        WHERE group_id = ? FOR UPDATE]], { membership.group_id })
    local groupTypeId = tonumber(organization and organization.group_type_id)
    if not groupTypeId or math.type(groupTypeId) ~= 'integer' or groupTypeId < 1 then
        return nil, nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The activation group type is unavailable.', true)
    end
    local rows = tx.many([[SELECT schema.id, schema.public_id,
            schema.owner_resource, schema.owner_epoch, schema.group_type_id,
            schema.namespace, schema.attribute_key, schema.value_kind,
            schema.required_value, schema.validation_json, schema.schema_version,
            schema.version, schema.has_default, schema.default_value_string,
            schema.default_value_integer, schema.default_value_decimal,
            schema.default_value_boolean,
            DATE_FORMAT(schema.default_value_datetime, '%Y-%m-%d %H:%i:%s.%f')
                AS default_value_datetime,
            schema.default_value_json
        FROM synex_group_attribute_schemas AS schema
        WHERE schema.status = 'active'
            AND (schema.group_type_id = ?
                OR (schema.group_type_id IS NULL AND NOT EXISTS (
                    SELECT 1 FROM synex_group_attribute_schemas AS scoped_schema
                    WHERE scoped_schema.namespace = schema.namespace
                        AND scoped_schema.attribute_key = schema.attribute_key
                        AND scoped_schema.group_type_id = ?
                )))
        ORDER BY schema.namespace ASC, schema.attribute_key ASC, schema.id ASC
        LIMIT 257 FOR UPDATE]], { groupTypeId, groupTypeId },
        MAXIMUM_EFFECTIVE_SCHEMAS + 1)
    if #rows > MAXIMUM_EFFECTIVE_SCHEMAS then
        return nil, nil, Foundation.domainError('READ_MODEL_TOO_LARGE',
            'The organization type exposes too many effective attribute schemas.')
    end
    local seen = {}
    for _, schema in ipairs(rows) do
        local key = tostring(schema.namespace) .. ':' .. tostring(schema.attribute_key)
        if seen[key] then
            return nil, nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The effective attribute schema scope is ambiguous.', true)
        end
        seen[key] = true
        local scopedId = tonumber(schema.group_type_id)
        if schema.group_type_id ~= nil and scopedId ~= groupTypeId then
            return nil, nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'A foreign attribute schema scope entered activation.', true)
        end
    end
    return rows, groupTypeId, nil
end

local function materializeDefault(tx, membership, runtime, schema, rules, value)
    local values = typedAttributeValue(
        tx, runtime, schema.value_kind, rules, value)
    if not values then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute default violates its schema.', true, {
                namespace = schema.namespace,
                key = schema.attribute_key
            })
    end
    local id, idError = publicId(runtime, 'group_attribute')
    if not id then return nil, idError end
    tx.query([[INSERT INTO synex_group_membership_attributes
        (public_id, membership_id, attribute_schema_id, value_kind,
         value_string, value_integer, value_decimal, value_boolean,
         value_datetime, value_json, updated_by_ref, version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, CAST(? AS DATETIME(6)), ?, ?, 1)]], {
        id, membership.id, schema.id, schema.value_kind,
        values.value_string, values.value_integer, values.value_decimal,
        values.value_boolean, values.value_datetime, values.value_json,
        membership.character_id
    })
    return id, nil
end

local function enforceMembershipActivation(tx, membership, runtime)
    local membershipId = type(membership) == 'table' and tonumber(membership.id) or nil
    local groupId = type(membership) == 'table' and tonumber(membership.group_id) or nil
    if not membershipId or math.type(membershipId) ~= 'integer' or membershipId < 1
        or not groupId or math.type(groupId) ~= 'integer' or groupId < 1
        or type(membership.character_id) ~= 'string'
        or not Foundation.isPublicId(membership.character_id) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Membership activation attribute context is invalid.')
    end
    local schemas, groupTypeId, schemaError = effectiveActivationSchemas(tx, membership)
    if not schemas then return nil, schemaError end
    local existingRows = tx.many([[SELECT attribute.public_id,
            attribute.attribute_schema_id, attribute.value_kind,
            attribute.value_string, attribute.value_integer, attribute.value_decimal,
            attribute.value_boolean,
            DATE_FORMAT(attribute.value_datetime, '%Y-%m-%d %H:%i:%s.%f')
                AS value_datetime,
            attribute.value_json, attribute.version
        FROM synex_group_membership_attributes AS attribute
        INNER JOIN synex_group_attribute_schemas AS schema
            ON schema.id = attribute.attribute_schema_id
        WHERE attribute.membership_id = ? AND schema.status = 'active'
            AND (schema.group_type_id = ?
                OR (schema.group_type_id IS NULL AND NOT EXISTS (
                    SELECT 1 FROM synex_group_attribute_schemas AS scoped_schema
                    WHERE scoped_schema.namespace = schema.namespace
                        AND scoped_schema.attribute_key = schema.attribute_key
                        AND scoped_schema.group_type_id = ?
                )))
        ORDER BY attribute.attribute_schema_id ASC LIMIT 257 FOR UPDATE]],
        { membershipId, groupTypeId, groupTypeId }, MAXIMUM_EFFECTIVE_SCHEMAS + 1)
    if #existingRows > MAXIMUM_EFFECTIVE_SCHEMAS then
        return nil, Foundation.domainError('READ_MODEL_TOO_LARGE',
            'The membership has too many effective stored attributes.')
    end
    local existing = {}
    for _, row in ipairs(existingRows) do
        local schemaId = tonumber(row.attribute_schema_id)
        if not schemaId or math.type(schemaId) ~= 'integer' or schemaId < 1
            or existing[schemaId] ~= nil then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'The stored membership attribute set is invalid.', true)
        end
        existing[schemaId] = row
    end

    local materialized, validated = 0, 0
    for _, schema in ipairs(schemas) do
        local schemaId = tonumber(schema.id)
        local ownerEpoch = tonumber(schema.owner_epoch)
        if not schemaId or math.type(schemaId) ~= 'integer' or schemaId < 1
            or not ownerEpoch or math.type(ownerEpoch) ~= 'integer' or ownerEpoch < 1
            or not ATTRIBUTE_TYPES[schema.value_kind] then
            return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                'An effective attribute schema is invalid.', true)
        end
        local rules, rulesError = decodeStoredRules(runtime, schema)
        if not rules then return nil, rulesError end
        local stored = existing[schemaId]
        if stored then
            if stored.value_kind ~= schema.value_kind then
                return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                    'A membership attribute kind differs from its schema.', true)
            end
            local value = storedAttributeValue(runtime, schema.value_kind, stored)
            if value == nil then
                return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                    'A stored membership attribute value is invalid.', true)
            end
            local validValue = typedAttributeValue(
                tx, runtime, schema.value_kind, rules, value)
            if not validValue then
                return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                    'A stored membership attribute violates its active schema.', true)
            end
            validated = validated + 1
        elseif tonumber(schema.has_default) == 1 then
            local defaultValue = storedAttributeValue(
                runtime, schema.value_kind, schema, 'default_')
            if defaultValue == nil then
                return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
                    'An active attribute schema default is invalid.', true)
            end
            local created, createError = materializeDefault(
                tx, membership, runtime, schema, rules, defaultValue)
            if not created then return nil, createError end
            materialized = materialized + 1
        elseif tonumber(schema.required_value) == 1 then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A required membership attribute has no deterministic default.', false, {
                    namespace = schema.namespace,
                    key = schema.attribute_key
                })
        end
    end
    return {
        schemas = #schemas,
        validated = validated,
        materialized = materialized
    }, nil
end

return {
    enforceMembershipActivation = enforceMembershipActivation
}
end
