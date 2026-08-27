return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local AttributeValues = require('server.persistence.governance_attribute_values')(Foundation)
local ATTRIBUTE_TYPES = AttributeValues.ATTRIBUTE_TYPES
local ATTRIBUTE_VISIBILITY = {
    public = true,
    members = true,
    management = true,
    staff = true,
    hidden = true,
    server_only = true,
    private = true
}
local rejected = Shared.rejected
local isObject = Shared.isObject
local publicId = Shared.publicId
local activeGroup = Shared.activeGroup
local canonical = Shared.canonical
local handlers = { read = {}, execute = {} }
local validateAttributeRules = AttributeValues.validateAttributeRules
local storedAttributeValue = AttributeValues.storedAttributeValue
local typedAttributeValue = AttributeValues.typedAttributeValue
local decodeStoredRules = AttributeValues.decodeStoredRules

local function ownerContext(context)
    local owner = type(context) == 'table' and context.caller or nil
    local epoch = type(context) == 'table' and context.callerEpoch or nil
    if type(owner) ~= 'string' or #owner < 3 or #owner > 64
        or not owner:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$')
        or type(epoch) ~= 'number' or math.type(epoch) ~= 'integer' or epoch < 1 then
        return nil, nil, Foundation.domainError('VALIDATION_FAILED',
            'The resource owner context is invalid.')
    end
    return owner, epoch, nil
end

local function validateSchemaIdentity(request)
    if type(request.namespace) ~= 'string' or #request.namespace < 2
        or #request.namespace > 64
        or not request.namespace:match('^[a-z][a-z0-9_-]+$')
        or type(request.key) ~= 'string' or #request.key < 2 or #request.key > 64
        or not request.key:match('^[a-z][a-z0-9_.:%-]+$')
        or type(request.schema_version) ~= 'number'
        or math.type(request.schema_version) ~= 'integer'
        or request.schema_version < 1 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The attribute schema identity or schema_version is invalid.')
    end
    if request.group_type ~= nil and (type(request.group_type) ~= 'string'
        or #request.group_type < 2 or #request.group_type > 64
        or not request.group_type:match('^[a-z][a-z0-9_-]+$')) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The attribute schema group_type scope is invalid.')
    end
    if request.capability ~= nil and (type(request.capability) ~= 'string'
        or #request.capability < 1 or #request.capability > 96
        or not request.capability:match('^[a-z][a-z0-9._*%-]*$')) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The attribute schema capability is invalid.')
    end
    return true, nil
end

local function resolveRegistrationScope(tx, groupType)
    if groupType == nil then
        return { id = nil, scopeId = 0, key = 'global' }, nil
    end
    local row = tx.one([[SELECT id, public_id, type_key, status
        FROM synex_group_types WHERE type_key = ? FOR UPDATE]], { groupType })
    if not row then
        return nil, Foundation.domainError('GROUP_TYPE_NOT_FOUND',
            'The requested attribute schema group type does not exist.')
    end
    if row.status ~= 'active' then
        return nil, Foundation.domainError('GROUP_TYPE_INACTIVE',
            'The requested attribute schema group type is not active.')
    end
    local internalId = tonumber(row.id)
    if not internalId or math.type(internalId) ~= 'integer' or internalId < 1
        or row.type_key ~= groupType then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute schema group type is invalid.', true)
    end
    return {
        id = internalId,
        scopeId = internalId,
        key = 'type:' .. row.type_key,
        type = row.type_key,
        publicId = row.public_id
    }, nil
end

local function scopedRegistryKey(scope, namespace, key)
    local candidate = 'attribute_schema:' .. scope.key .. ':' .. namespace .. ':' .. key
    if #candidate > 128 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The scoped attribute schema registry key exceeds 128 bytes.')
    end
    return candidate, nil
end

local function deferRegistry(runtime, context, owner, epoch, generation, key, value)
    if not Foundation.isCallable(runtime.deferRegistry) then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The attribute schema registry commit coordinator is unavailable.', true)
    end
    return runtime.deferRegistry(
        context, 'attributeSchemas', owner, epoch, generation, key, value)
end

local function sameDefault(valueKind, existing, requested)
    local hasDefault = tonumber(existing.has_default) == 1
    if hasDefault ~= (requested ~= nil) then return false end
    if not hasDefault then return true end
    if valueKind == 'integer' then
        return tonumber(existing.default_value_integer) == requested.value_integer
    end
    if valueKind == 'decimal' then
        return tonumber(existing.default_value_decimal) == requested.value_decimal
    end
    if valueKind == 'boolean' then
        return tonumber(existing.default_value_boolean) == requested.value_boolean
    end
    if valueKind == 'datetime' then
        return existing.default_value_datetime == requested.value_datetime
    end
    if valueKind == 'json' then
        return existing.default_value_json == requested.value_json
    end
    return existing.default_value_string == requested.value_string
end

function handlers.execute.attributes_register_schema(tx, request, runtime, context)
    local owner, epoch, ownerError = ownerContext(context)
    if not owner then return nil, ownerError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if not Foundation.isCallable(runtime.requireRegistryOwnerSession) then
        return rejected('DATABASE_ERROR',
            'The attribute registry synchronization boundary is unavailable.', true)
    end
    local synchronized, synchronizationError = runtime.requireRegistryOwnerSession(
        tx, owner, epoch)
    if not synchronized then return nil, synchronizationError, nil end
    local validIdentity, identityError = validateSchemaIdentity(request)
    if not validIdentity then return nil, identityError, nil end
    if not ATTRIBUTE_TYPES[request.type] or not ATTRIBUTE_VISIBILITY[request.visibility] then
        return rejected('VALIDATION_FAILED',
            'Attribute type or visibility is not supported.')
    end
    local rules, rulesError = validateAttributeRules(request.type, request.validation)
    if not rules then return nil, rulesError, nil end
    if request.required ~= nil then
        if type(request.required) ~= 'boolean'
            or rules.required ~= nil and rules.required ~= request.required then
            return rejected('VALIDATION_FAILED',
                'Attribute required declarations must be boolean and consistent.')
        end
        rules.required = request.required
    end
    local hasDefault = request.default ~= nil
    if rules.required == true and not hasDefault then
        return rejected('VALIDATION_FAILED',
            'A required attribute schema must declare a type-valid default.')
    end
    local defaultValues
    if hasDefault then
        local defaultError
        defaultValues, defaultError = typedAttributeValue(
            tx, runtime, request.type, rules, request.default)
        if not defaultValues then return nil, defaultError, nil end
    end
    local rulesJson, encodeError = canonical(runtime, rules)
    if not rulesJson then return nil, encodeError, nil end
    local scope, scopeError = resolveRegistrationScope(tx, request.group_type)
    if not scope then return nil, scopeError, nil end
    local registryKey, registryKeyError = scopedRegistryKey(
        scope, request.namespace, request.key)
    if not registryKey then return nil, registryKeyError, nil end
    local existing = tx.one([[SELECT id, public_id, owner_resource, owner_epoch,
            group_type_id, namespace, attribute_key, value_kind, contract_type,
            visibility, required_value, validation_json, capability, schema_version,
            status, version, has_default, default_value_string,
            default_value_integer, default_value_decimal, default_value_boolean,
            DATE_FORMAT(default_value_datetime, '%Y-%m-%d %H:%i:%s.%f')
                AS default_value_datetime,
            default_value_json
        FROM synex_group_attribute_schemas
        WHERE namespace = ? AND group_type_scope_id = ? AND attribute_key = ?
        FOR UPDATE]], { request.namespace, scope.scopeId, request.key })
    local schemaId, version, changed, previous
    if existing then
        if existing.owner_resource ~= owner then
            return rejected('TYPE_OWNER_CONFLICT',
                'The scoped attribute schema belongs to another resource.')
        end
        if existing.status == 'retired' then
            return rejected('INVALID_TRANSITION',
                'A retired attribute schema cannot be registered again.')
        end
        local storedSchemaVersion = tonumber(existing.schema_version)
        local storedVersion = tonumber(existing.version)
        local storedEpoch = tonumber(existing.owner_epoch)
        local storedId = tonumber(existing.id)
        local storedScopeId = existing.group_type_id ~= nil
            and tonumber(existing.group_type_id) or nil
        if not storedId or math.type(storedId) ~= 'integer' or storedId < 1
            or not Foundation.isPublicId(existing.public_id)
            or existing.namespace ~= request.namespace
            or existing.attribute_key ~= request.key
            or (scope.id == nil and existing.group_type_id ~= nil)
            or (scope.id ~= nil and (not storedScopeId
                or math.type(storedScopeId) ~= 'integer'
                or storedScopeId ~= scope.id))
            or not storedSchemaVersion or math.type(storedSchemaVersion) ~= 'integer'
            or storedSchemaVersion < 1 or not storedVersion
            or math.type(storedVersion) ~= 'integer' or storedVersion < 1
            or not storedEpoch or math.type(storedEpoch) ~= 'integer' or storedEpoch < 1 then
            return rejected('DATABASE_RESULT_INVALID',
                'The stored attribute schema ownership or version is invalid.', true)
        end
        local same = existing.value_kind == request.type
            and existing.contract_type == request.type
            and existing.visibility == request.visibility
            and tonumber(existing.required_value) == (rules.required == true and 1 or 0)
            and existing.validation_json == rulesJson
            and existing.capability == request.capability
            and sameDefault(request.type, existing, defaultValues)
        if request.schema_version < storedSchemaVersion
            or request.schema_version == storedSchemaVersion and not same then
            return rejected('CONCURRENT_MODIFICATION',
                'Attribute schema changes must advance schema_version.', true, {
                    expected_minimum = storedSchemaVersion + 1,
                    actual = request.schema_version
                })
        end
        schemaId, version = existing.public_id, storedVersion
        changed = request.schema_version > storedSchemaVersion
            or storedEpoch ~= epoch or existing.status ~= 'active'
        previous = {
            schema_version = storedSchemaVersion,
            owner_epoch = storedEpoch,
            status = existing.status,
            version = storedVersion
        }
        if changed then
            if tx.affected([[UPDATE synex_group_attribute_schemas
                    SET value_kind = ?, contract_type = ?, visibility = ?,
                        required_value = ?, validation_json = ?, capability = ?,
                        schema_version = ?, owner_epoch = ?, status = 'active',
                        has_default = ?, default_value_string = ?,
                        default_value_integer = ?, default_value_decimal = ?,
                        default_value_boolean = ?,
                        default_value_datetime = CAST(? AS DATETIME(6)),
                        default_value_json = ?, version = version + 1
                    WHERE id = ? AND version = ?]], {
                request.type, request.type, request.visibility,
                rules.required == true and 1 or 0, rulesJson, request.capability,
                request.schema_version, epoch, hasDefault and 1 or 0,
                defaultValues and defaultValues.value_string or nil,
                defaultValues and defaultValues.value_integer or nil,
                defaultValues and defaultValues.value_decimal or nil,
                defaultValues and defaultValues.value_boolean or nil,
                defaultValues and defaultValues.value_datetime or nil,
                defaultValues and defaultValues.value_json or nil,
                storedId, storedVersion
            }) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The attribute schema changed during registration.', true)
            end
            version = storedVersion + 1
        end
    else
        local id, idError = publicId(runtime, 'group_attr_schema')
        if not id then return nil, idError, nil end
        tx.query([[INSERT INTO synex_group_attribute_schemas
            (public_id, owner_resource, owner_epoch, group_type_id,
             attribute_key, display_name, value_kind, visibility, required_value,
             validation_json, has_default, default_value_string,
             default_value_integer, default_value_decimal, default_value_boolean,
             default_value_datetime, default_value_json, status, version,
             namespace, contract_type, capability, schema_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                CAST(? AS DATETIME(6)), ?, 'active', 1, ?, ?, ?, ?)]], {
            id, owner, epoch, scope.id, request.key, request.key,
            request.type, request.visibility, rules.required == true and 1 or 0,
            rulesJson, hasDefault and 1 or 0,
            defaultValues and defaultValues.value_string or nil,
            defaultValues and defaultValues.value_integer or nil,
            defaultValues and defaultValues.value_decimal or nil,
            defaultValues and defaultValues.value_boolean or nil,
            defaultValues and defaultValues.value_datetime or nil,
            defaultValues and defaultValues.value_json or nil,
            request.namespace, request.type, request.capability,
            request.schema_version
        })
        schemaId, version, changed = id, 1, true
    end

    local deferred, deferError = deferRegistry(
        runtime, context, owner, epoch, synchronized.generation, registryKey, {
            publicId = schemaId,
            namespace = request.namespace,
            key = request.key,
            scope = scope.key,
            groupType = scope.type,
            type = request.type,
            visibility = request.visibility,
            capability = request.capability,
            required = rules.required == true,
            hasDefault = hasDefault,
            schemaVersion = request.schema_version,
            ownerEpoch = epoch,
            version = version
        })
    if not deferred then return nil, deferError, nil end
    local effects = {}
    if changed then
        effects[1] = runtime.effect('attribute_schema.registered',
            'attribute_schema', schemaId, nil, nil, previous, {
                namespace = request.namespace,
                key = request.key,
                scope = scope.key,
                schema_version = request.schema_version,
                owner_epoch = epoch,
                required = rules.required == true,
                has_default = hasDefault,
                version = version
            }, 'attribute_schema_registered', version)
    end
    return runtime.success(schemaId, 'attribute_schema',
        changed and 'active' or 'unchanged', version), nil, effects
end

local function effectiveSchemaJoin(lock)
    return [[SELECT schema.id, schema.public_id, schema.owner_resource,
            schema.owner_epoch, schema.group_type_id, schema.namespace,
            schema.attribute_key, schema.value_kind, schema.visibility,
            schema.required_value, schema.validation_json, schema.capability,
            schema.schema_version, schema.status, schema.version,
            schema.has_default, schema.default_value_string,
            schema.default_value_integer, schema.default_value_decimal,
            schema.default_value_boolean,
            DATE_FORMAT(schema.default_value_datetime, '%Y-%m-%d %H:%i:%s.%f')
                AS default_value_datetime,
            schema.default_value_json
        FROM synex_group_organization_profiles AS organization
        INNER JOIN synex_group_attribute_schemas AS schema
            ON schema.namespace = ? AND schema.attribute_key = ?
            AND schema.status = 'active'
            AND (schema.group_type_id = organization.group_type_id
                OR (schema.group_type_id IS NULL AND NOT EXISTS (
                    SELECT 1 FROM synex_group_attribute_schemas AS scoped_schema
                    WHERE scoped_schema.namespace = schema.namespace
                        AND scoped_schema.attribute_key = schema.attribute_key
                        AND scoped_schema.group_type_id = organization.group_type_id
                )))
        WHERE organization.group_id = ?
        ORDER BY CASE WHEN schema.group_type_id IS NULL THEN 1 ELSE 0 END,
            schema.id ASC LIMIT 1]] .. (lock and ' FOR UPDATE' or '')
end

local function schemaCapability(tx, runtime, schema, groupPublicId, actorCharacterId)
    if schema.capability == nil then return true, nil end
    if type(schema.capability) ~= 'string' or #schema.capability < 1
        or #schema.capability > 96
        or not schema.capability:match('^[a-z][a-z0-9._*%-]*$') then
        return nil, Foundation.domainError('DATABASE_RESULT_INVALID',
            'The stored attribute capability is invalid.', true)
    end
    if not Foundation.isCallable(runtime.authorize) then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The Groups attribute capability boundary is unavailable.', true)
    end
    local actor, authorizationError = runtime.authorize(
        tx, groupPublicId, actorCharacterId, schema.capability, 'group')
    if not actor then
        return nil, authorizationError or Foundation.domainError(
            'INSUFFICIENT_PERMISSION',
            'The actor lacks the attribute schema capability.')
    end
    return true, nil
end

local function resourceOwnsSchema(schema, context)
    local epoch = tonumber(schema.owner_epoch)
    return type(context) == 'table'
        and context.caller == schema.owner_resource
        and type(context.callerEpoch) == 'number'
        and math.type(context.callerEpoch) == 'integer'
        and epoch ~= nil and context.callerEpoch == epoch
end

local function missingAttribute()
    return rejected('ATTRIBUTE_NOT_FOUND',
        'The requested membership attribute does not exist.')
end

local function concealAttributeAccess(accessError)
    if type(accessError) == 'table'
        and (accessError.retryable == true
            or accessError.code == 'CORE_UNAVAILABLE'
            or accessError.code == 'DATABASE_ERROR'
            or accessError.code == 'DATABASE_RESULT_INVALID') then
        return rejected('DATABASE_ERROR',
            'Membership attribute access could not be evaluated.', true)
    end
    return missingAttribute()
end

function handlers.read.attributes_get(tx, request, runtime, context)
    local row = tx.one([[SELECT attribute.public_id AS attribute_public_id,
            attribute.value_kind, attribute.value_string, attribute.value_integer,
            attribute.value_decimal, attribute.value_boolean,
            DATE_FORMAT(attribute.value_datetime, '%Y-%m-%d %H:%i:%s.%f')
                AS value_datetime,
            attribute.value_json, attribute.version,
            schema.namespace, schema.attribute_key, schema.visibility,
            schema.capability, schema.owner_resource, schema.owner_epoch,
            membership.id AS membership_internal_id,
            membership.public_id AS membership_public_id,
            profile.character_id, profile.lifecycle_state,
            group_record.id AS group_internal_id,
            group_record.public_id AS group_public_id
        FROM synex_group_memberships AS membership
        INNER JOIN synex_group_membership_profiles AS profile
            ON profile.membership_id = membership.id
        INNER JOIN synex_groups AS group_record ON group_record.id = membership.group_id
        INNER JOIN synex_group_organization_profiles AS organization
            ON organization.group_id = membership.group_id
        INNER JOIN synex_group_attribute_schemas AS schema
            ON schema.namespace = ? AND schema.attribute_key = ?
            AND schema.status = 'active'
            AND (schema.group_type_id = organization.group_type_id
                OR (schema.group_type_id IS NULL AND NOT EXISTS (
                    SELECT 1 FROM synex_group_attribute_schemas AS scoped_schema
                    WHERE scoped_schema.namespace = schema.namespace
                        AND scoped_schema.attribute_key = schema.attribute_key
                        AND scoped_schema.group_type_id = organization.group_type_id
                )))
        LEFT JOIN synex_group_membership_attributes AS attribute
            ON attribute.membership_id = membership.id
            AND attribute.attribute_schema_id = schema.id
        WHERE membership.public_id = ?
        ORDER BY CASE WHEN schema.group_type_id IS NULL THEN 1 ELSE 0 END,
            schema.id ASC LIMIT 1]], {
        request.namespace, request.key, request.membership_id
    })
    if not row or row.attribute_public_id == nil then
        return missingAttribute()
    end

    local visible = false
    if row.visibility == 'public' then
        visible = true
    elseif row.visibility == 'private' then
        visible = row.character_id == request.actor_character_id
    elseif row.visibility == 'members' then
        visible = tx.one([[SELECT membership.id
            FROM synex_group_memberships AS membership
            INNER JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = membership.id
            WHERE membership.group_id = ? AND profile.character_id = ?
                AND profile.lifecycle_state = 'ACTIVE' LIMIT 1]], {
            row.group_internal_id, request.actor_character_id
        }) ~= nil
    elseif row.visibility == 'management' then
        if not Foundation.isCallable(runtime.authorize) then
            return rejected('DATABASE_ERROR',
                'The Groups attribute authorization boundary is unavailable.', true)
        end
        local actor, authorizationError = runtime.authorize(
            tx, row.group_public_id, request.actor_character_id,
            'synex.groups.attributes.read', 'group')
        if not actor then return concealAttributeAccess(authorizationError) end
        visible = true
    elseif row.visibility == 'staff' then
        if not Foundation.isCallable(runtime.checkCorePermission) then
            return rejected('DATABASE_ERROR',
                'The Core staff permission boundary is unavailable.', true)
        end
        local permitted, permissionError = runtime.checkCorePermission(
            request.actor_character_id, 'synex.groups.attributes.staff.read')
        if not permitted then
            return concealAttributeAccess(permissionError)
        end
        visible = true
    elseif row.visibility == 'hidden' then
        visible = row.character_id == request.actor_character_id
            or resourceOwnsSchema(row, context)
    elseif row.visibility == 'server_only' then
        visible = resourceOwnsSchema(row, context)
    else
        return rejected('DATABASE_RESULT_INVALID',
            'The stored attribute visibility is invalid.', true)
    end
    if not visible then
        return missingAttribute()
    end
    local capable, capabilityError = schemaCapability(
        tx, runtime, row, row.group_public_id, request.actor_character_id)
    if not capable then return concealAttributeAccess(capabilityError) end

    local value = storedAttributeValue(runtime, row.value_kind, row)
    if value == nil then
        return rejected('DATABASE_RESULT_INVALID',
            'The stored membership attribute value is invalid.', true)
    end
    local version = tonumber(row.version)
    if not version or math.type(version) ~= 'integer' or version < 1 then
        return rejected('DATABASE_RESULT_INVALID',
            'The stored membership attribute version is invalid.', true)
    end
    return {
        attribute_id = row.attribute_public_id,
        membership_id = row.membership_public_id,
        group_id = row.group_public_id,
        namespace = row.namespace,
        key = row.attribute_key,
        type = row.value_kind,
        visibility = row.visibility,
        value = value,
        version = version
    }, nil
end

function handlers.execute.attributes_set(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end
    if not Foundation.isCallable(runtime.authorize) then
        return rejected('DATABASE_ERROR',
            'The Groups attribute authorization boundary is unavailable.', true)
    end
    local actor, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        'synex.groups.attributes.manage', 'group')
    if not actor then return nil, authorizationError end
    local schema = tx.one(effectiveSchemaJoin(true), {
        request.namespace, request.key, membership.group_id
    })
    if not schema then
        return rejected('VALIDATION_FAILED',
            'The active attribute schema does not exist for this group type.')
    end
    if schema.visibility == 'server_only' and not resourceOwnsSchema(schema, context) then
        return rejected('INSUFFICIENT_PERMISSION',
            'Only the current attribute schema owner epoch may write this server-only value.')
    end
    local capable, capabilityError = schemaCapability(
        tx, runtime, schema, membership.group_public_id, request.actor_character_id)
    if not capable then return nil, capabilityError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if membership.lifecycle_state ~= 'ACTIVE' then
        return rejected('MEMBERSHIP_NOT_ACTIVE',
            'Attributes can only be written for an active membership.')
    end
    local rules, rulesError = decodeStoredRules(runtime, schema)
    if not rules then return nil, rulesError end
    local values, valueError = typedAttributeValue(
        tx, runtime, schema.value_kind, rules, request.value)
    if not values then return nil, valueError end
    local existing = tx.one([[SELECT public_id, value_kind, value_string, value_integer,
            value_decimal, value_boolean,
            DATE_FORMAT(value_datetime, '%Y-%m-%d %H:%i:%s.%f') AS value_datetime,
            value_json, version
        FROM synex_group_membership_attributes
        WHERE membership_id = ? AND attribute_schema_id = ? FOR UPDATE]],
        { membership.id, schema.id })
    local attributeId, version, before
    if existing then
        version = tonumber(existing.version)
        if request.expected_version == nil or request.expected_version ~= version then
            return rejected('CONCURRENT_MODIFICATION',
                'Updating an attribute requires its current expected_version.', true)
        end
        before = {
            namespace = request.namespace,
            key = request.key,
            value_present = storedAttributeValue(runtime, schema.value_kind, existing) ~= nil,
            version = version
        }
        if tx.affected([[UPDATE synex_group_membership_attributes
                SET value_kind = ?, value_string = ?, value_integer = ?, value_decimal = ?,
                    value_boolean = ?, value_datetime = CAST(? AS DATETIME(6)), value_json = ?,
                    updated_by_ref = ?, version = version + 1
                WHERE membership_id = ? AND attribute_schema_id = ? AND version = ?]], {
            schema.value_kind, values.value_string, values.value_integer,
            values.value_decimal, values.value_boolean, values.value_datetime,
            values.value_json, request.actor_character_id,
            membership.id, schema.id, version
        }) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The attribute changed while it was being updated.', true)
        end
        attributeId, version = existing.public_id, version + 1
    else
        if request.expected_version ~= nil and request.expected_version ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'A new attribute can only use expected_version 1.', true)
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
            request.actor_character_id
        })
        attributeId, version = id, 1
    end
    local touched, touchError = runtime.touchGroup(tx, membership.group_id)
    if not touched then return nil, touchError end
    local response = runtime.success(attributeId, 'attribute', 'active', version)
    return response, nil, {
        runtime.effect('attribute.changed', 'attribute', attributeId,
            membership.group_public_id, membership.character_id, before, {
                namespace = request.namespace,
                key = request.key,
                value_present = true,
                version = version
            }, request.reason, version)
    }
end

return handlers
end
