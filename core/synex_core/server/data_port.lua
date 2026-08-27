local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.dataPort = function(deps)
    local platform = assert(deps.platform, 'data port requires platform')
    local foundation = assert(deps.foundation, 'data port requires foundation')
    local database = assert(deps.database, 'data port requires database')
    local owners = assert(deps.owners, 'data port requires owners')
    local sha256 = assert(deps.sha256, 'data port requires hashing')
    local manifestFor = assert(deps.manifestFor, 'data port requires manifest lookup')

    local maximumSqlBytes = 32768
    local maximumParameters = 128
    local maximumRows = 8192
    local maximumResultBytes = 4194304
    local maximumRequestBytes = 8388608
    local maximumTransactionStatements = 65535
    local allowedStatementKinds = { SELECT = 'read', INSERT = 'write', UPDATE = 'write', DELETE = 'write' }
    local forbiddenKeywords = {
        ALTER = true, ANALYZE = true, BENCHMARK = true, CALL = true, CREATE = true,
        DEALLOCATE = true, DO = true, DROP = true, DUMPFILE = true, EXECUTE = true,
        EXPLAIN = true, FLUSH = true, GET_LOCK = true, GRANT = true, HANDLER = true,
        IS_FREE_LOCK = true, IS_USED_LOCK = true, KILL = true, LOAD = true, LOCK = true,
        OPTIMIZE = true, PREPARE = true, RENAME = true, REPAIR = true,
        REPLACE = true, RELEASE_LOCK = true, REVOKE = true, SHOW = true, SLEEP = true,
        TRUNCATE = true, UNLOCK = true, USE = true, OUTFILE = true
    }
    local allowedSqlCalls = {
        AND = true, AS = true, BY = true, CASE = true, ELSE = true,
        CAST = true, COALESCE = true, CONCAT = true, COUNT = true,
        CURRENT_TIMESTAMP = true, DATE_FORMAT = true, DATETIME = true,
        EXISTS = true, FROM = true, GROUP = true, HAVING = true, IN = true,
        JOIN = true, JSON_OBJECT = true, JSON_SEARCH = true,
        LOWER = true, MAX = true, SHA2 = true, SUBSTRING = true, SUM = true,
        NOT = true, ON = true, OR = true, ORDER = true, SELECT = true,
        THEN = true, TIMESTAMPADD = true, UNION = true, UNIX_TIMESTAMP = true,
        USING = true, VALUES = true, WHEN = true, WHERE = true
    }

    local function validResourceOwner(value)
        return type(value) == 'string' and #value <= 64
            and value:match('^synex_[a-z0-9_]+$') ~= nil
    end

    local function exactObject(value, allowed, code, message)
        if type(value) ~= 'table' or getmetatable(value) ~= nil then
            return nil, foundation.error(code, message)
        end
        for key in pairs(value) do
            if type(key) ~= 'string' or not allowed[key] then
                return nil, foundation.error(code, message)
            end
        end
        return true, nil
    end

    local function canonicalEncoder()
        local active, keys = {}, 0
        local function encode(value, depth)
            local valueType = type(value)
            if valueType == 'nil' then return 'null' end
            if valueType == 'boolean' or valueType == 'string' then
                local ok, encoded = pcall(platform.jsonEncode, value)
                if not ok or type(encoded) ~= 'string' then error('JSON encoding failed', 0) end
                return encoded
            end
            if valueType == 'number' then
                if value ~= value or value == math.huge or value == -math.huge then
                    error('JSON number is not finite', 0)
                end
                return tostring(value)
            end
            local containerKind = valueType == 'table' and foundation.jsonContainerKind(value) or nil
            if valueType ~= 'table' or not containerKind or depth > 12 or active[value] then
                error('JSON value is not a bounded acyclic container', 0)
            end
            active[value] = true
            local count, maximumIndex, keyType = 0, 0, nil
            for key in next, value do
                keys = keys + 1
                count = count + 1
                if keys > 1024 then active[value] = nil error('JSON value has too many keys', 0) end
                local currentType = type(key)
                if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentType ~= 'string' or #key < 1 or #key > 128 then
                    active[value] = nil error('JSON object key is invalid', 0)
                end
                if keyType and keyType ~= currentType then
                    active[value] = nil error('JSON container mixes key types', 0)
                end
                keyType = currentType
            end
            local encoded
            if keyType == 'number' or (count == 0 and containerKind == 'array') then
                if containerKind == 'object' or maximumIndex ~= count then
                    active[value] = nil error('JSON array is sparse or has the wrong type', 0)
                end
                local items = {}
                for index = 1, count do items[index] = encode(value[index], depth + 1) end
                encoded = '[' .. table.concat(items, ',') .. ']'
            else
                if containerKind == 'array' then
                    active[value] = nil error('JSON object has the wrong type', 0)
                end
                local ordered = {}
                for key in next, value do ordered[#ordered + 1] = key end
                table.sort(ordered)
                local properties = {}
                for index, key in ipairs(ordered) do
                    local ok, encodedKey = pcall(platform.jsonEncode, key)
                    if not ok or type(encodedKey) ~= 'string' then
                        active[value] = nil error('JSON key encoding failed', 0)
                    end
                    properties[index] = encodedKey .. ':' .. encode(value[key], depth + 1)
                end
                encoded = '{' .. table.concat(properties, ',') .. '}'
            end
            active[value] = nil
            return encoded
        end
        return function(value)
            active, keys = {}, 0
            return encode(value, 1)
        end
    end
    local canonical = canonicalEncoder()

    local function boundedJson(value, maximumBytes, invalidCode)
        local ok, encoded = pcall(canonical, value)
        if not ok then
            return nil, foundation.error(invalidCode or 'INVALID_JSON_VALUE',
                'The value must be bounded plain JSON data.')
        end
        if #encoded > maximumBytes then
            return nil, foundation.error('PAYLOAD_TOO_LARGE',
                'The encoded value exceeds its supported byte limit.')
        end
        return encoded, nil
    end

    local function sqlNull(value)
        if type(value) ~= 'table' or foundation.jsonContainerKind(value) == nil then
            return false
        end
        local count = 0
        for key, item in pairs(value) do
            count = count + 1
            if key ~= '__synex_database_null' or item ~= true then return false end
        end
        return count == 1
    end

    local function parameters(candidate)
        if candidate == nil then return {}, nil end
        local containerKind = type(candidate) == 'table'
            and foundation.jsonContainerKind(candidate) or nil
        if containerKind == nil or containerKind == 'object' then
            return nil, foundation.error('INVALID_DATABASE_PARAMETERS',
                'Database parameters must be a dense plain array.')
        end
        local count, maximumIndex = 0, 0
        for key, value in pairs(candidate) do
            count = count + 1
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1
                or count > maximumParameters then
                return nil, foundation.error('INVALID_DATABASE_PARAMETERS',
                    'Database parameters must be a bounded dense array.')
            end
            maximumIndex = math.max(maximumIndex, key)
            local valueType = type(value)
            if valueType ~= 'string' and valueType ~= 'number' and valueType ~= 'boolean'
                and not sqlNull(value) then
                return nil, foundation.error('INVALID_DATABASE_PARAMETERS',
                    'Database parameters contain an unsupported value.')
            end
            if valueType == 'string' and #value > 65536
                or valueType == 'number' and (value ~= value or value == math.huge
                    or value == -math.huge) then
                return nil, foundation.error('INVALID_DATABASE_PARAMETERS',
                    'Database parameters contain an out-of-bounds value.')
            end
        end
        if count ~= maximumIndex then
            return nil, foundation.error('INVALID_DATABASE_PARAMETERS',
                'Database parameters must be contiguous.')
        end
        local copied = {}
        for index = 1, count do
            if not sqlNull(candidate[index]) then copied[index] = candidate[index] end
        end
        -- Cfx MessagePack serializes a sparse table as a map. The numeric zero
        -- marker keeps even a trailing SQL NULL positional; oxmysql ignores it
        -- while translating the 1-based binding map into its JavaScript array.
        if count > 0 then copied[0] = false end
        return copied, nil, count
    end

    local function inspectSql(sql)
        if type(sql) ~= 'string' or #sql < 1 or #sql > maximumSqlBytes
            or sql:find('[%z\1-\8\11\12\14-\31\127]') then
            return nil, foundation.error('INVALID_DATABASE_STATEMENT',
                'The database statement is empty or outside its supported bounds.')
        end
        local output, placeholderCount, state, quote, index = {}, 0, 'plain', nil, 1
        while index <= #sql do
            local character = sql:sub(index, index)
            local following = sql:sub(index + 1, index + 1)
            if state == 'string' then
                output[#output + 1] = ' '
                if character == quote then
                    if following == quote then
                        output[#output + 1] = ' '
                        index = index + 1
                    else state, quote = 'plain', nil end
                elseif character == '\\' and following ~= '' then
                    output[#output + 1] = ' '
                    index = index + 1
                end
            elseif state == 'identifier' then
                output[#output + 1] = character
                if character == '`' then
                    if following == '`' then
                        output[#output + 1] = following
                        index = index + 1
                    else state = 'plain' end
                end
            else
                if character == "'" or character == '"' then
                    state, quote = 'string', character
                    output[#output + 1] = ' '
                elseif character == '`' then
                    state = 'identifier'
                    output[#output + 1] = character
                elseif character == '?' then
                    placeholderCount = placeholderCount + 1
                    output[#output + 1] = character
                elseif character == ';' or character == '#' or character == '@'
                    or character == '-' and following == '-'
                    or character == '/' and following == '*' then
                    return nil, foundation.error('INVALID_DATABASE_STATEMENT',
                        'Multiple statements, comments, and SQL variables are not supported.')
                else output[#output + 1] = character end
            end
            index = index + 1
        end
        if state ~= 'plain' then
            return nil, foundation.error('INVALID_DATABASE_STATEMENT',
                'The database statement contains an unterminated literal or identifier.')
        end

        local sanitized = table.concat(output)
        local tokens, cursor = {}, 1
        while cursor <= #sanitized do
            local character = sanitized:sub(cursor, cursor)
            if character:match('%s') then
                cursor = cursor + 1
            elseif character == '`' then
                local closing = sanitized:find('`', cursor + 1, true)
                if not closing then
                    return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                        'The database identifier is unterminated.')
                end
                local name = sanitized:sub(cursor + 1, closing - 1)
                if not name:match('^[a-z0-9_]+$') then
                    return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                        'Database identifiers must use canonical lower-case names.')
                end
                tokens[#tokens + 1] = { kind = 'identifier', value = name, upper = name:upper() }
                cursor = closing + 1
            elseif character:match('[A-Za-z_]') then
                local ending = cursor
                while ending <= #sanitized
                    and sanitized:sub(ending, ending):match('[A-Za-z0-9_]') do
                    ending = ending + 1
                end
                local word = sanitized:sub(cursor, ending - 1)
                tokens[#tokens + 1] = {
                    kind = 'word', value = word:lower(), upper = word:upper()
                }
                cursor = ending
            else
                tokens[#tokens + 1] = { kind = 'symbol', value = character, upper = character }
                cursor = cursor + 1
            end
        end
        if #tokens == 0 then
            return nil, foundation.error('INVALID_DATABASE_STATEMENT',
                'The database statement contains no operation.')
        end

        local depths, parenthesisDepth = {}, 0
        for tokenIndex, token in ipairs(tokens) do
            depths[tokenIndex] = parenthesisDepth
            if token.value == '(' then parenthesisDepth = parenthesisDepth + 1
            elseif token.value == ')' then
                parenthesisDepth = parenthesisDepth - 1
                if parenthesisDepth < 0 then
                    return nil, foundation.error('INVALID_DATABASE_STATEMENT',
                        'The database statement has unbalanced parentheses.')
                end
            end
        end
        if parenthesisDepth ~= 0 then
            return nil, foundation.error('INVALID_DATABASE_STATEMENT',
                'The database statement has unbalanced parentheses.')
        end

        local mainIndex, ctes, cteByName = 1, {}, {}
        if tokens[1].kind == 'word' and tokens[1].upper == 'WITH' then
            local recursive = tokens[2] and tokens[2].upper == 'RECURSIVE'
            local cteCursor = recursive and 3 or 2
            mainIndex = nil
            while cteCursor <= #tokens do
                local alias = tokens[cteCursor]
                if not alias or alias.kind ~= 'word' and alias.kind ~= 'identifier'
                    or cteByName[alias.value] then
                    return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                        'A CTE declaration has an invalid or duplicate alias.')
                end
                local asToken = tokens[cteCursor + 1]
                local opening = tokens[cteCursor + 2]
                if not asToken or asToken.upper ~= 'AS'
                    or not opening or opening.value ~= '(' then
                    return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                        'CTE column lists and non-canonical declarations are not supported.')
                end
                local closing
                for tokenIndex = cteCursor + 3, #tokens do
                    if tokens[tokenIndex].value == ')'
                        and depths[tokenIndex] == depths[cteCursor + 2] + 1 then
                        closing = tokenIndex
                        break
                    end
                end
                if not closing or closing == cteCursor + 3 then
                    return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                        'A CTE declaration must contain a bounded query body.')
                end
                local declaration = {
                    name = alias.value,
                    order = #ctes + 1,
                    opening = cteCursor + 2,
                    closing = closing,
                    recursive = recursive == true
                }
                ctes[#ctes + 1] = declaration
                cteByName[declaration.name] = declaration
                local following = tokens[closing + 1]
                if following and following.value == ',' then
                    cteCursor = closing + 2
                else
                    mainIndex = closing + 1
                    break
                end
            end
            if not mainIndex or not tokens[mainIndex]
                or depths[mainIndex] ~= 0 then
                return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                    'A CTE must terminate in a supported data statement.')
            end
        end
        local main = tokens[mainIndex]
        local access = main and allowedStatementKinds[main.upper] or nil
        if not access then
            return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                'Only SELECT, INSERT, UPDATE, DELETE, and WITH statements are supported.')
        end
        for tokenIndex, token in ipairs(tokens) do
            if token.kind == 'word' and token.upper == 'WITH' and tokenIndex ~= 1 then
                return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                    'Nested CTE declarations are not supported.')
            end
            if token.kind == 'word' and forbiddenKeywords[token.upper]
                and tokenIndex ~= mainIndex then
                return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                    'The statement contains a forbidden database operation.')
            end
            local following = tokens[tokenIndex + 1]
            local previous = tokens[tokenIndex - 1]
            local insertTargetColumns = main.upper == 'INSERT' and previous
                and previous.upper == 'INTO' and tokenIndex > mainIndex
            if (token.kind == 'word' or token.kind == 'identifier')
                and following and following.value == '('
                and not insertTargetColumns
                and not allowedSqlCalls[token.upper] then
                return nil, foundation.error('DATABASE_STATEMENT_FORBIDDEN',
                    'The statement contains a database function outside the safe allowlist.')
            end
        end

        local function cteReference(name, referenceIndex)
            local target = cteByName[name]
            if not target then return false end
            if referenceIndex >= mainIndex then return true end
            local container
            for _, declaration in ipairs(ctes) do
                if referenceIndex > declaration.opening
                    and referenceIndex < declaration.closing then
                    container = declaration
                    break
                end
            end
            if not container then return false end
            if target.order < container.order then return true end
            if target.order ~= container.order or not container.recursive then return false end
            local bodyDepth = depths[container.opening] + 1
            for tokenIndex = container.opening + 1, referenceIndex - 1 do
                if depths[tokenIndex] == bodyDepth and tokens[tokenIndex].upper == 'UNION' then
                    return true
                end
            end
            return false
        end

        local tables = {}
        local referenceKeywords = { FROM = true, JOIN = true, USING = true }
        local clauseKeywords = {
            CROSS = true, FOR = true, GROUP = true, HAVING = true, INNER = true,
            JOIN = true, LEFT = true, LIMIT = true, ON = true, ORDER = true,
            OUTER = true, RETURNING = true, RIGHT = true, SET = true, UNION = true,
            VALUES = true, WHERE = true
        }
        if main.upper == 'UPDATE' then referenceKeywords.UPDATE = true end
        if main.upper == 'INSERT' then referenceKeywords.INTO = true end
        for tokenIndex, token in ipairs(tokens) do
            if token.kind == 'word' and referenceKeywords[token.upper] then
                local referenced = tokens[tokenIndex + 1]
                if referenced and referenced.value ~= '(' then
                    if referenced.kind ~= 'word' and referenced.kind ~= 'identifier' then
                        return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                            'A database table reference is invalid.')
                    end
                    if tokens[tokenIndex + 2] and tokens[tokenIndex + 2].value == '.' then
                        return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                            'Schema-qualified database table references are not supported.')
                    end
                    if not cteReference(referenced.value, tokenIndex + 1) then
                        tables[referenced.value] = true
                    end
                    local referenceDepth = depths[tokenIndex]
                    for lookahead = tokenIndex + 2, #tokens do
                        local candidate = tokens[lookahead]
                        if depths[lookahead] < referenceDepth
                            or depths[lookahead] == referenceDepth
                                and candidate.kind == 'word'
                                and clauseKeywords[candidate.upper] then
                            break
                        end
                        if depths[lookahead] == referenceDepth and candidate.value == ',' then
                            return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                                'Comma-separated table lists are not supported; use explicit joins.')
                        end
                    end
                elseif not referenced then
                    return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                        'A database table reference is missing.')
                end
            end
        end
        if next(tables) == nil and access ~= 'read' then
            return nil, foundation.error('DATABASE_TABLE_REFERENCE_INVALID',
                'A write statement must reference an owned table.')
        end
        return {
            access = access,
            kind = main.upper,
            placeholders = placeholderCount,
            tables = tables
        }, nil
    end

    local function ownedTables(owner)
        local manifest = manifestFor(owner)
        local list = type(manifest) == 'table' and manifest.dataOwnership
            and manifest.dataOwnership.tables or nil
        if type(list) ~= 'table' then
            return nil, foundation.error('DATABASE_OWNERSHIP_UNAVAILABLE',
                'The calling resource has no validated data ownership declaration.')
        end
        local owned = {}
        for _, tableName in ipairs(list) do owned[tableName] = true end
        return owned, nil
    end

    local function prepare(owner, sql, candidateParameters, requiredAccess)
        local inspected, statementError = inspectSql(sql)
        if not inspected then return nil, statementError end
        if requiredAccess and inspected.access ~= requiredAccess then
            return nil, foundation.error('DATABASE_ACCESS_MISMATCH',
                'The statement kind does not match the requested database operation.')
        end
        local values, parameterError, parameterCount = parameters(candidateParameters)
        if not values then return nil, parameterError end
        if inspected.placeholders ~= parameterCount then
            return nil, foundation.error('DATABASE_PARAMETER_MISMATCH',
                'The statement placeholder count does not match its parameter count.')
        end
        local owned, ownershipError = ownedTables(owner)
        if not owned then return nil, ownershipError end
        for tableName in pairs(inspected.tables) do
            if not owned[tableName] then
                return nil, foundation.error('DATABASE_TABLE_NOT_OWNED',
                    'The statement references a table not owned by the calling resource.', {
                        details = { table = tableName }
                    })
            end
        end
        return {
            sql = sql,
            parameters = values,
            access = inspected.access,
            kind = inspected.kind
        }, nil
    end

    local function deadline(timeoutMs)
        timeoutMs = timeoutMs == nil and 5000 or timeoutMs
        if type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer'
            or timeoutMs < 100 or timeoutMs > 15000 then
            return nil, foundation.error('INVALID_DATABASE_DEADLINE',
                'Database timeout must be an integer from 100 through 15000 milliseconds.')
        end
        return foundation.monotonicMs() + timeoutMs, nil
    end

    local function available(owner, epoch, deadlineAt)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The database operation owner restarted.', { retryable = true })
        end
        if foundation.monotonicMs() > deadlineAt then
            return nil, foundation.error('DATABASE_DEADLINE_EXCEEDED',
                'The database operation exceeded its deadline.', { retryable = true })
        end
        return true, nil
    end

    local function boundedRows(rows, limit, byteLimit)
        if type(rows) ~= 'table' or #rows > limit then
            return nil, foundation.error('DATABASE_RESULT_LIMIT',
                'The database result exceeded its configured row limit.')
        end
        local encoded, encodeError = boundedJson(rows, byteLimit,
            'DATABASE_RESULT_INVALID')
        if not encoded then return nil, encodeError end
        return foundation.copy(rows), nil
    end

    local function affectedRows(value)
        local result = type(value) == 'table' and tonumber(value.affectedRows) or tonumber(value)
        if not result or math.type(result) ~= 'integer' or result < 0
            or result > 9007199254740991 then return nil end
        return result
    end

    local function writeResult(value, kind)
        local affected = affectedRows(value)
        if affected == nil then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'The database write returned an invalid affected-row count.')
        end
        local result = { kind = kind:lower(), affectedRows = affected }
        if kind == 'INSERT' and type(value) == 'table' then
            local insertId = tonumber(value.insertId)
            if insertId ~= nil then
                if math.type(insertId) ~= 'integer' or insertId < 0
                    or insertId > 9007199254740991 then
                    return nil, foundation.error('DATABASE_RESULT_INVALID',
                        'The database insert returned an invalid identifier.')
                end
                if insertId > 0 then result.insertId = insertId end
            end
        end
        return result, nil
    end

    local function transactionAdapter(owner, epoch, deadlineAt, query, bounds)
        local statements = 0
        local transaction = {}
        local function execute(sql, candidateParameters, requiredAccess, limit)
            local stillCurrent, currentError = available(owner, epoch, deadlineAt)
            if not stillCurrent then return nil, currentError end
            statements = statements + 1
            if statements > bounds.statements then
                return nil, foundation.error('DATABASE_STATEMENT_LIMIT',
                    'The transaction exceeded its statement limit.')
            end
            local statement, statementError = prepare(
                owner, sql, candidateParameters, requiredAccess)
            if not statement then return nil, statementError end
            local raw = query(statement.sql, statement.parameters)
            if statement.access == 'read' then
                return boundedRows(raw, limit or bounds.rows, bounds.resultBytes)
            end
            return writeResult(raw, statement.kind)
        end
        function transaction:query(sql, values, limit)
            if limit ~= nil and (type(limit) ~= 'number' or math.type(limit) ~= 'integer'
                or limit < 1 or limit > bounds.rows) then
                return nil, foundation.error('INVALID_DATABASE_REQUEST',
                    'Transaction query row limit is invalid.')
            end
            return execute(sql, values, nil, limit)
        end
        function transaction:many(sql, values, limit)
            if limit ~= nil and (type(limit) ~= 'number' or math.type(limit) ~= 'integer'
                or limit < 1 or limit > bounds.rows) then
                return nil, foundation.error('INVALID_DATABASE_REQUEST',
                    'Transaction query row limit is invalid.')
            end
            return execute(sql, values, 'read', limit)
        end
        function transaction:one(sql, values)
            local rows, rowsError = self:many(sql, values, 1)
            if not rows then return nil, rowsError end
            return rows[1], nil
        end
        function transaction:affected(sql, values)
            local result, resultError = execute(sql, values, 'write')
            return result and result.affectedRows or nil, resultError
        end
        function transaction:update(sql, values) return self:affected(sql, values) end
        function transaction:insert(sql, values)
            local statement, statementError = prepare(owner, sql, values, 'write')
            if not statement then return nil, statementError end
            if statement.kind ~= 'INSERT' then
                return nil, foundation.error('DATABASE_ACCESS_MISMATCH',
                    'Transaction insert requires an INSERT statement.')
            end
            local result, resultError = execute(sql, values, 'write')
            if not result then return nil, resultError end
            if not result.insertId then
                return nil, foundation.error('DATABASE_RESULT_INVALID',
                    'The database insert did not return an identifier.')
            end
            return result.insertId, nil
        end
        return transaction
    end

    local function lockReceiptCapacity(query, owner)
        local globalRows = query([[SELECT `entry_count`, `global_limit`, `owner_limit`
            FROM `synex_domain_receipt_capacity`
            WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
        local global = globalRows[1]
        local globalCount = global and tonumber(global.entry_count) or nil
        local globalLimit = global and tonumber(global.global_limit) or nil
        local ownerLimit = global and tonumber(global.owner_limit) or nil
        if #globalRows ~= 1 or not globalCount or math.type(globalCount) ~= 'integer'
            or not globalLimit or math.type(globalLimit) ~= 'integer'
            or not ownerLimit or math.type(ownerLimit) ~= 'integer'
            or globalCount < 0 or ownerLimit < 1 or globalLimit < ownerLimit
            or globalCount > globalLimit then
            return nil, foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                'Atomic domain receipt capacity is invalid.')
        end
        local ownerCreated = affectedRows(query(
            [[INSERT IGNORE INTO `synex_domain_receipt_owner_capacity`
            (`owner_resource`, `entry_count`) VALUES (?, 0)]], { owner }))
        if ownerCreated ~= 0 and ownerCreated ~= 1 then
            return nil, foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                'Atomic domain receipt owner capacity could not be initialized.')
        end
        local ownerRows = query([[SELECT `entry_count`
            FROM `synex_domain_receipt_owner_capacity`
            WHERE `owner_resource` = ? FOR UPDATE]], { owner }) or {}
        local ownerCount = ownerRows[1] and tonumber(ownerRows[1].entry_count) or nil
        if #ownerRows ~= 1 or not ownerCount or math.type(ownerCount) ~= 'integer'
            or ownerCount < 0 or ownerCount > ownerLimit or ownerCount > globalCount then
            return nil, foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                'Atomic domain receipt owner capacity is invalid.')
        end
        return {
            globalCount = globalCount,
            globalLimit = globalLimit,
            ownerCount = ownerCount,
            ownerLimit = ownerLimit
        }, nil
    end

    local port = {}

    function port:null()
        return { __synex_database_null = true }
    end

    function port:read(owner, epoch, request)
        local valid, requestError = exactObject(request,
            {
                sql = true, parameters = true, maximumRows = true,
                maximumResultBytes = true, timeoutMs = true
            },
            'INVALID_DATABASE_REQUEST', 'Database read request is invalid.')
        if not valid then return nil, requestError end
        local rowLimit = request.maximumRows == nil and 128 or request.maximumRows
        local byteLimit = request.maximumResultBytes == nil and 262144
            or request.maximumResultBytes
        if type(rowLimit) ~= 'number' or math.type(rowLimit) ~= 'integer'
            or rowLimit < 1 or rowLimit > maximumRows
            or type(byteLimit) ~= 'number' or math.type(byteLimit) ~= 'integer'
            or byteLimit < 1 or byteLimit > maximumResultBytes then
            return nil, foundation.error('INVALID_DATABASE_REQUEST',
                'Database result bounds are outside the supported range.')
        end
        local statement, statementError = prepare(owner, request.sql, request.parameters, 'read')
        if not statement then return nil, statementError end
        local deadlineAt, deadlineError = deadline(request.timeoutMs)
        if not deadlineAt then return nil, deadlineError end
        local current, currentError = available(owner, epoch, deadlineAt)
        if not current then return nil, currentError end
        local rows, queryError = database:query(statement.sql, statement.parameters)
        if not rows then return nil, queryError end
        current, currentError = available(owner, epoch, deadlineAt)
        if not current then return nil, currentError end
        return boundedRows(rows, rowLimit, byteLimit)
    end

    function port:write(owner, epoch, request)
        local valid, requestError = exactObject(request,
            { sql = true, parameters = true, timeoutMs = true },
            'INVALID_DATABASE_REQUEST', 'Database write request is invalid.')
        if not valid then return nil, requestError end
        local statement, statementError = prepare(owner, request.sql, request.parameters, 'write')
        if not statement then return nil, statementError end
        local deadlineAt, deadlineError = deadline(request.timeoutMs)
        if not deadlineAt then return nil, deadlineError end
        local result, domainError
        local committed, transactionError = database:withTransaction(function(query)
            local current
            current, domainError = available(owner, epoch, deadlineAt)
            if not current then return false end
            local raw = query(statement.sql, statement.parameters)
            result, domainError = writeResult(raw, statement.kind)
            if not result then return false end
            current, domainError = available(owner, epoch, deadlineAt)
            return current == true
        end)
        if not committed then return nil, domainError or transactionError end
        return result, nil
    end

    function port:transaction(owner, epoch, request, handler)
        local valid, requestError = exactObject(request, {
            operation = true, idempotencyKey = true, request = true,
            timeoutMs = true, maximumRows = true, maximumResultBytes = true,
            maximumRequestBytes = true, maximumResponseBytes = true,
            maximumStatements = true
        }, 'INVALID_DATABASE_TRANSACTION', 'Database transaction request is invalid.')
        if not valid then return nil, requestError end
        if type(request.operation) ~= 'string' or #request.operation < 1
            or #request.operation > 64
            or not request.operation:match('^[a-z][a-z0-9_.%-]*$')
            or request.operation:match('[._%-]$')
            or type(request.idempotencyKey) ~= 'string'
            or #request.idempotencyKey < 8 or #request.idempotencyKey > 128
            or not request.idempotencyKey:match('^[A-Za-z0-9_.:%-]+$')
            or not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_DATABASE_TRANSACTION',
                'Transaction operation, idempotency key, or handler is invalid.')
        end
        local rowLimit = request.maximumRows == nil and 128 or request.maximumRows
        local resultLimit = request.maximumResultBytes == nil and 262144
            or request.maximumResultBytes
        local requestLimit = request.maximumRequestBytes == nil and 1048576
            or request.maximumRequestBytes
        local responseLimit = request.maximumResponseBytes == nil and 65536
            or request.maximumResponseBytes
        local statementLimit = request.maximumStatements == nil and 4096
            or request.maximumStatements
        if type(rowLimit) ~= 'number' or math.type(rowLimit) ~= 'integer'
            or rowLimit < 1 or rowLimit > maximumRows
            or type(resultLimit) ~= 'number' or math.type(resultLimit) ~= 'integer'
            or resultLimit < 1 or resultLimit > maximumResultBytes
            or type(requestLimit) ~= 'number' or math.type(requestLimit) ~= 'integer'
            or requestLimit < 1 or requestLimit > maximumRequestBytes
            or type(responseLimit) ~= 'number' or math.type(responseLimit) ~= 'integer'
            or responseLimit < 1 or responseLimit > maximumResultBytes
            or type(statementLimit) ~= 'number' or math.type(statementLimit) ~= 'integer'
            or statementLimit < 1 or statementLimit > maximumTransactionStatements then
            return nil, foundation.error('INVALID_DATABASE_TRANSACTION',
                'Transaction result bounds are invalid.')
        end
        local deadlineAt, deadlineError = deadline(request.timeoutMs)
        if not deadlineAt then return nil, deadlineError end
        local requestJson, requestJsonError = boundedJson(request.request or {}, requestLimit,
            'INVALID_DATABASE_TRANSACTION')
        if not requestJson then return nil, requestJsonError end
        local requestHash = sha256(requestJson)
        local response, replayed, domainError
        local committed, transactionError = database:withTransaction(function(query)
            response, replayed, domainError = nil, false, nil
            local current
            current, domainError = available(owner, epoch, deadlineAt)
            if not current then return false end
            local claimed = affectedRows(query([[INSERT IGNORE INTO
                `synex_domain_operation_receipts`
                (`owner_resource`, `operation_name`, `idempotency_key`, `request_hash`,
                    `state`, `response_json`, `expires_at`)
                VALUES (?, ?, ?, ?, 'pending', NULL,
                    TIMESTAMPADD(DAY, 7, CURRENT_TIMESTAMP(6)))]],
                { owner, request.operation, request.idempotencyKey, requestHash }))
            if claimed ~= 0 and claimed ~= 1 then
                domainError = foundation.error('IDEMPOTENCY_CLAIM_INVALID',
                    'The atomic domain receipt could not be claimed safely.')
                return false
            end
            local receipts = query([[SELECT `request_hash`, `state`, `response_json`
                FROM `synex_domain_operation_receipts`
                WHERE `owner_resource` = ? AND `operation_name` = ?
                    AND `idempotency_key` = ? LIMIT 1 FOR UPDATE]],
                { owner, request.operation, request.idempotencyKey }) or {}
            if #receipts > 1 then
                domainError = foundation.error('IDEMPOTENCY_STATE_INVALID',
                    'The atomic domain receipt lookup returned an invalid result.')
                return false
            end
            local receipt = receipts[1]
            if not receipt then
                domainError = foundation.error('IDEMPOTENCY_CLAIM_INVALID',
                    'The atomic domain receipt claim is not visible to its transaction.')
                return false
            end
            if claimed == 0 then
                local capacity
                capacity, domainError = lockReceiptCapacity(query, owner)
                if not capacity then return false end
                if capacity.globalCount < 1 or capacity.ownerCount < 1 then
                    domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'The atomic domain receipt is absent from its capacity counters.')
                    return false
                end
                if receipt.request_hash ~= requestHash then
                    domainError = foundation.error('IDEMPOTENCY_CONFLICT',
                        'The idempotency key was used with a different request.')
                    return false
                end
                if receipt.state ~= 'completed' or type(receipt.response_json) ~= 'string'
                    or #receipt.response_json > responseLimit then
                    domainError = foundation.error('IDEMPOTENCY_INDETERMINATE',
                        'The atomic domain receipt is not safely replayable.', { retryable = true })
                    return false
                end
                local decoded, value = pcall(platform.jsonDecode, receipt.response_json)
                if not decoded then
                    domainError = foundation.error('IDEMPOTENCY_RESPONSE_CORRUPT',
                        'The atomic domain receipt response is invalid.')
                    return false
                end
                response, replayed = foundation.copy(value), true
                return true
            end
            if receipt.request_hash ~= requestHash or receipt.state ~= 'pending'
                or receipt.response_json ~= nil then
                domainError = foundation.error('IDEMPOTENCY_CLAIM_INVALID',
                    'The atomic domain receipt claim has an invalid initial state.')
                return false
            end
            local transaction = transactionAdapter(owner, epoch, deadlineAt, query, {
                rows = rowLimit,
                resultBytes = resultLimit,
                statements = statementLimit
            })
            local invoked, value, handlerError = foundation.safeCall(handler, transaction)
            if not invoked then
                domainError = foundation.error('DATABASE_TRANSACTION_HANDLER_FAILED',
                    'The domain transaction handler raised an exception.')
                return false
            end
            if handlerError then
                domainError = type(handlerError) == 'table' and handlerError
                    or foundation.error('DATABASE_TRANSACTION_REJECTED',
                        'The domain transaction handler rejected the operation.')
                return false
            end
            current, domainError = available(owner, epoch, deadlineAt)
            if not current then return false end
            local responseJson, responseError = boundedJson(value, responseLimit,
                'DATABASE_TRANSACTION_RESPONSE_INVALID')
            if not responseJson then domainError = responseError return false end
            local capacity
            capacity, domainError = lockReceiptCapacity(query, owner)
            if not capacity then return false end
            if capacity.globalCount >= capacity.globalLimit
                or capacity.ownerCount >= capacity.ownerLimit then
                domainError = foundation.error('IDEMPOTENCY_CAPACITY_EXCEEDED',
                    'Atomic domain receipt capacity is exhausted.', {
                        details = {
                            scope = capacity.globalCount >= capacity.globalLimit
                                and 'global' or 'owner'
                        }
                    })
                return false
            end
            local globalUpdated = affectedRows(query([[UPDATE `synex_domain_receipt_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `singleton_id` = 1 AND `entry_count` = ?
                    AND `entry_count` < `global_limit`]], { capacity.globalCount }))
            local ownerUpdated = affectedRows(query([[UPDATE `synex_domain_receipt_owner_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `owner_resource` = ? AND `entry_count` = ?
                    AND `entry_count` < ?]],
                { owner, capacity.ownerCount, capacity.ownerLimit }))
            if globalUpdated ~= 1 or ownerUpdated ~= 1 then
                domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'Atomic domain receipt capacity changed unexpectedly.')
                return false
            end
            local completed = affectedRows(query([[UPDATE `synex_domain_operation_receipts`
                SET `state` = 'completed', `response_json` = ?,
                    `completed_at` = CURRENT_TIMESTAMP(6)
                WHERE `owner_resource` = ? AND `operation_name` = ?
                    AND `idempotency_key` = ? AND `request_hash` = ?
                    AND `state` = 'pending']], {
                responseJson, owner, request.operation, request.idempotencyKey, requestHash
            }))
            if completed ~= 1 then
                domainError = foundation.error('IDEMPOTENCY_CLAIM_LOST',
                    'The atomic domain receipt changed before commit.', { retryable = true })
                return false
            end
            current, domainError = available(owner, epoch, deadlineAt)
            if not current then return false end
            response = foundation.copy(value)
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return response, nil, { replayed = replayed }
    end

    function port:maintenance(owner, epoch, request, handler)
        local valid, requestError = exactObject(request, {
            operation = true, timeoutMs = true, maximumRows = true,
            maximumResultBytes = true, maximumResponseBytes = true,
            maximumStatements = true
        }, 'INVALID_DATABASE_TRANSACTION', 'Database maintenance request is invalid.')
        if not valid then return nil, requestError end
        if type(request.operation) ~= 'string' or #request.operation < 1
            or #request.operation > 64
            or not request.operation:match('^[a-z][a-z0-9_.%-]*$')
            or request.operation:match('[._%-]$')
            or not foundation.isCallable(handler) then
            return nil, foundation.error('INVALID_DATABASE_TRANSACTION',
                'Database maintenance operation or handler is invalid.')
        end
        local rowLimit = request.maximumRows == nil and 256 or request.maximumRows
        local resultLimit = request.maximumResultBytes == nil and 1048576
            or request.maximumResultBytes
        local responseLimit = request.maximumResponseBytes == nil and 65536
            or request.maximumResponseBytes
        local statementLimit = request.maximumStatements == nil and 256
            or request.maximumStatements
        if type(rowLimit) ~= 'number' or math.type(rowLimit) ~= 'integer'
            or rowLimit < 1 or rowLimit > maximumRows
            or type(resultLimit) ~= 'number' or math.type(resultLimit) ~= 'integer'
            or resultLimit < 1 or resultLimit > maximumResultBytes
            or type(responseLimit) ~= 'number' or math.type(responseLimit) ~= 'integer'
            or responseLimit < 1 or responseLimit > 1048576
            or type(statementLimit) ~= 'number' or math.type(statementLimit) ~= 'integer'
            or statementLimit < 1 or statementLimit > maximumTransactionStatements then
            return nil, foundation.error('INVALID_DATABASE_TRANSACTION',
                'Database maintenance bounds are invalid.')
        end
        local deadlineAt, deadlineError = deadline(request.timeoutMs)
        if not deadlineAt then return nil, deadlineError end
        local response, domainError
        local committed, transactionError = database:withTransaction(function(query)
            response, domainError = nil, nil
            local current
            current, domainError = available(owner, epoch, deadlineAt)
            if not current then return false end
            local transaction = transactionAdapter(owner, epoch, deadlineAt, query, {
                rows = rowLimit,
                resultBytes = resultLimit,
                statements = statementLimit
            })
            local invoked, value, handlerError = foundation.safeCall(handler, transaction)
            if not invoked then
                domainError = foundation.error('DATABASE_TRANSACTION_HANDLER_FAILED',
                    'The maintenance transaction handler raised an exception.')
                return false
            end
            if handlerError then
                domainError = type(handlerError) == 'table' and handlerError
                    or foundation.error('DATABASE_TRANSACTION_REJECTED',
                        'The maintenance transaction handler rejected the operation.')
                return false
            end
            current, domainError = available(owner, epoch, deadlineAt)
            if not current then return false end
            local encoded, responseError = boundedJson(value, responseLimit,
                'DATABASE_TRANSACTION_RESPONSE_INVALID')
            if not encoded then domainError = responseError return false end
            response = foundation.copy(value)
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return response, nil
    end

    function port:compactExpired(limit)
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 250 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Domain receipt compaction limit must be 1 through 250.')
        end
        local report = { removed = 0, owners = 0 }
        local domainError
        local committed, transactionError = database:withTransaction(function(query)
            domainError = nil
            local rows = query([[SELECT `owner_resource`, `operation_name`, `idempotency_key`
                FROM `synex_domain_operation_receipts`
                FORCE INDEX (`idx_domain_receipts_expiry`)
                WHERE `expires_at` <= CURRENT_TIMESTAMP(6)
                ORDER BY `expires_at`, `owner_resource`, `operation_name`, `idempotency_key`
                LIMIT ? FOR UPDATE]], { limit }) or {}
            if #rows > limit then
                domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'Atomic domain receipt compaction returned an invalid batch.')
                return false
            end
            local globalRows = query([[SELECT `entry_count`
                FROM `synex_domain_receipt_capacity`
                WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
            local globalCount = globalRows[1] and tonumber(globalRows[1].entry_count) or nil
            if #globalRows ~= 1 or not globalCount or math.type(globalCount) ~= 'integer'
                or globalCount < 0 or #rows > globalCount then
                domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                    'Atomic domain receipt capacity is invalid during compaction.')
                return false
            end
            local ownerCounts = {}
            for _, row in ipairs(rows) do
                if not validResourceOwner(row.owner_resource) then
                    domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'Atomic domain receipt compaction returned an invalid owner.')
                    return false
                end
                ownerCounts[row.owner_resource] = (ownerCounts[row.owner_resource] or 0) + 1
                local removed = affectedRows(query([[DELETE FROM `synex_domain_operation_receipts`
                    WHERE `owner_resource` = ? AND `operation_name` = ?
                        AND `idempotency_key` = ? AND `expires_at` <= CURRENT_TIMESTAMP(6)]], {
                    row.owner_resource, row.operation_name, row.idempotency_key
                }))
                if removed ~= 1 then
                    domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'Atomic domain receipt changed during compaction.')
                    return false
                end
            end
            local ownersRemoved = 0
            for ownerName, count in pairs(ownerCounts) do
                local ownerRows = query([[SELECT `entry_count`
                    FROM `synex_domain_receipt_owner_capacity`
                    WHERE `owner_resource` = ? FOR UPDATE]], { ownerName }) or {}
                local current = ownerRows[1] and tonumber(ownerRows[1].entry_count) or nil
                if #ownerRows ~= 1 or not current or math.type(current) ~= 'integer'
                    or current < count then
                    domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'Atomic domain receipt owner capacity is inconsistent.')
                    return false
                end
                local updated = affectedRows(query([[UPDATE `synex_domain_receipt_owner_capacity`
                    SET `entry_count` = `entry_count` - ?
                    WHERE `owner_resource` = ? AND `entry_count` = ?]],
                    { count, ownerName, current }))
                if updated ~= 1 then
                    domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'Atomic domain receipt owner capacity changed during compaction.')
                    return false
                end
                ownersRemoved = ownersRemoved + 1
            end
            if #rows > 0 then
                local updated = affectedRows(query([[UPDATE `synex_domain_receipt_capacity`
                    SET `entry_count` = `entry_count` - ?
                    WHERE `singleton_id` = 1 AND `entry_count` = ?]],
                    { #rows, globalCount }))
                if updated ~= 1 then
                    domainError = foundation.error('IDEMPOTENCY_CAPACITY_INVALID',
                        'Atomic domain receipt capacity changed during compaction.')
                    return false
                end
            end
            report = { removed = #rows, owners = ownersRemoved }
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        return report, nil
    end

    return port
end
