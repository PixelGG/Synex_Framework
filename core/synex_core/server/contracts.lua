local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.contracts = function(deps)
    local foundation = assert(deps.foundation, 'contracts require foundation')
    local protocol = deps.protocol or SynexProtocol

    local function valueType(value)
        local kind = type(value)
        if kind == 'nil' then return 'null' end
        if kind == 'number' and math.type(value) == 'integer' then return 'integer' end
        if kind == 'table' then
            local containerKind = foundation.jsonContainerKind(value)
            if containerKind == 'array' then return 'array' end
            return 'object'
        end
        return kind
    end

    local function arrayLength(value)
        if type(value) ~= 'table' then return nil end
        local containerKind = foundation.jsonContainerKind(value)
        if not containerKind or containerKind == 'object' then return nil end
        local maximum = 0
        local count = 0
        for key in next, value do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then return nil end
            maximum = math.max(maximum, key)
            count = count + 1
        end
        if maximum ~= count then return nil end
        return count
    end

    -- Compile-time shape limits and a runtime operation budget keep matching linear and bounded.
    local patternLimits = {
        bytes = 256,
        tokens = 64,
        states = 64,
        repeatMaximum = 64,
        unboundedTokens = 8,
        unanchoredStates = 16,
        matchWork = 131072,
        cache = 256
    }
    -- The table validator shares this budget across oneOf/anyOf branches and deep comparisons.
    local validationLimits = {
        work = 65536,
        schemaWork = 65536,
        equalityDepth = 25,
        uniqueItems = 32
    }

    local function spendWork(state, amount)
        if not state then return true end
        state.work = (state.work or 0) + (amount or 1)
        return state.work <= (state.workLimit or validationLimits.work)
    end

    local function equals(left, right, workState, compared, depth)
        if not spendWork(workState, 1) then return nil, 'workBudget' end
        if type(left) ~= type(right) then return false, nil end
        if type(left) ~= 'table' then return left == right, nil end
        local leftContainer = foundation.jsonContainerKind(left)
        local rightContainer = foundation.jsonContainerKind(right)
        if not leftContainer or not rightContainer then return false, 'plainJson' end
        if leftContainer ~= 'plain' and rightContainer ~= 'plain'
            and leftContainer ~= rightContainer then return false, nil end
        depth = (depth or 0) + 1
        if depth > validationLimits.equalityDepth then return false, 'maxDepth' end
        compared = compared or {}
        compared[left] = compared[left] or {}
        local status = compared[left][right]
        if status == 'active' then return false, 'cycle' end
        if status == 'equal' then return true, nil end
        compared[left][right] = 'active'
        for key, value in next, left do
            if not spendWork(workState, 1) then return nil, 'workBudget' end
            local rightValue = rawget(right, key)
            if rightValue == nil then return false, nil end
            local same, comparisonError = equals(value, rightValue, workState, compared, depth)
            if comparisonError then return same, comparisonError end
            if not same then return false, nil end
        end
        for key in next, right do
            if not spendWork(workState, 1) then return nil, 'workBudget' end
            if rawget(left, key) == nil then return false, nil end
        end
        compared[left][right] = 'equal'
        return true, nil
    end
    local escapedPatternLiterals = {
        ['\\'] = true, ['^'] = true, ['$'] = true, ['.'] = true,
        ['*'] = true, ['+'] = true, ['?'] = true, ['{'] = true,
        ['}'] = true, ['['] = true, [']'] = true, ['('] = true,
        [')'] = true, ['|'] = true, ['/'] = true, ['-'] = true
    }
    local patternCache = {}
    local patternCacheOrder = {}
    local supportedSchemaTypes = {
        null = true, boolean = true, string = true, number = true,
        integer = true, array = true, object = true
    }
    local supportedSchemaKeywords = {
        ['$schema'] = true, ['$id'] = true, ['$comment'] = true,
        title = true, description = true, default = true, examples = true,
        deprecated = true, readOnly = true, writeOnly = true,
        type = true, const = true, enum = true, oneOf = true, anyOf = true,
        properties = true, required = true, additionalProperties = true,
        items = true, minItems = true, maxItems = true, uniqueItems = true,
        minLength = true, maxLength = true, pattern = true,
        minimum = true, maximum = true,
        exclusiveMinimum = true, exclusiveMaximum = true
    }

    local function parseEscapedPatternLiteral(pattern, index, inClass)
        local candidate = pattern:sub(index + 1, index + 1)
        if candidate == '' or not escapedPatternLiterals[candidate] or (candidate == '-' and not inClass) then
            return nil, index, 'only escaped regular-expression literals are supported'
        end
        return candidate:byte(), index + 2, nil
    end

    local function parsePatternClass(pattern, index)
        local characters = {}
        local negate = false
        local cursor = index + 1
        if pattern:sub(cursor, cursor) == '^' then negate = true; cursor = cursor + 1 end
        local members = 0
        while cursor <= #pattern and pattern:sub(cursor, cursor) ~= ']' do
            local first, nextCursor, parseError
            local character = pattern:sub(cursor, cursor)
            if character == '\\' then
                first, nextCursor, parseError = parseEscapedPatternLiteral(pattern, cursor, true)
                if not first then return nil, cursor, parseError end
            else
                local byte = character:byte()
                if not byte or byte < 0x20 or byte > 0x7e or character == '[' then
                    return nil, cursor, 'character classes support printable ASCII literals only'
                end
                first, nextCursor = byte, cursor + 1
            end

            if pattern:sub(nextCursor, nextCursor) == '-'
                and pattern:sub(nextCursor + 1, nextCursor + 1) ~= ']'
                and pattern:sub(nextCursor + 1, nextCursor + 1) ~= '' then
                local last, rangeCursor
                local rangeCharacter = pattern:sub(nextCursor + 1, nextCursor + 1)
                if rangeCharacter == '\\' then
                    last, rangeCursor, parseError = parseEscapedPatternLiteral(pattern, nextCursor + 1, true)
                    if not last then return nil, nextCursor + 1, parseError end
                else
                    local byte = rangeCharacter:byte()
                    if not byte or byte < 0x20 or byte > 0x7e
                        or rangeCharacter == '[' or rangeCharacter == '-' then
                        return nil, nextCursor + 1, 'character class range endpoint is invalid'
                    end
                    last, rangeCursor = byte, nextCursor + 2
                end
                if first > last then return nil, cursor, 'character class ranges must be ascending' end
                for codepoint = first, last do characters[codepoint] = true end
                cursor = rangeCursor
            else
                characters[first] = true
                cursor = nextCursor
            end
            members = members + 1
        end
        if pattern:sub(cursor, cursor) ~= ']' then return nil, cursor, 'character class is not closed' end
        if members == 0 then return nil, cursor, 'empty character classes are not supported' end
        return { kind = 'class', characters = characters, negate = negate }, cursor + 1, nil
    end

    local function parsePatternQuantifier(pattern, index)
        local character = pattern:sub(index, index)
        if character == '*' then return 0, nil, index + 1, nil end
        if character == '+' then return 1, nil, index + 1, nil end
        if character == '?' then return 0, 1, index + 1, nil end
        if character ~= '{' then return 1, 1, index, nil end

        local cursor = index + 1
        local firstDigit = cursor
        while pattern:sub(cursor, cursor):match('^%d$') do cursor = cursor + 1 end
        if cursor == firstDigit then return nil, nil, cursor, 'quantifier minimum is required' end
        local minimum = tonumber(pattern:sub(firstDigit, cursor - 1))
        local maximum = minimum
        if pattern:sub(cursor, cursor) == ',' then
            cursor = cursor + 1
            local maximumDigit = cursor
            while pattern:sub(cursor, cursor):match('^%d$') do cursor = cursor + 1 end
            if cursor == maximumDigit then
                return nil, nil, cursor, 'open-ended brace quantifiers are not supported'
            end
            maximum = tonumber(pattern:sub(maximumDigit, cursor - 1))
        end
        if pattern:sub(cursor, cursor) ~= '}' then return nil, nil, cursor, 'quantifier is not closed' end
        if not minimum or not maximum or minimum > maximum or maximum > patternLimits.repeatMaximum then
            return nil, nil, cursor, 'quantifier bounds are invalid or exceed the supported maximum'
        end
        return minimum, maximum, cursor + 1, nil
    end

    local function compilePattern(pattern)
        if type(pattern) ~= 'string' or #pattern > patternLimits.bytes then
            return nil, 'pattern must be a bounded string'
        end
        for index = 1, #pattern do
            local byte = pattern:byte(index)
            if not byte or byte < 0x20 or byte > 0x7e then
                return nil, 'patterns support printable ASCII syntax only'
            end
        end

        local anchoredStart = pattern:sub(1, 1) == '^'
        local cursor = anchoredStart and 2 or 1
        local tokens = {}
        local anchoredEnd = false
        while cursor <= #pattern do
            local character = pattern:sub(cursor, cursor)
            if character == '$' then
                if cursor ~= #pattern then return nil, 'the end anchor is only supported at the end' end
                anchoredEnd = true
                cursor = cursor + 1
                break
            end
            if character == '^' then return nil, 'the start anchor is only supported at the beginning' end

            local atom, nextCursor, parseError
            if character == '\\' then
                local literal
                literal, nextCursor, parseError = parseEscapedPatternLiteral(pattern, cursor, false)
                if literal then atom = { kind = 'literal', value = literal } end
            elseif character == '[' then
                atom, nextCursor, parseError = parsePatternClass(pattern, cursor)
            elseif character == '.' then
                atom, nextCursor = { kind = 'dot' }, cursor + 1
            elseif character == '*' or character == '+' or character == '?' or character == '{'
                or character == '}' or character == ']' or character == '(' or character == ')' or character == '|' then
                return nil, 'unsupported regular-expression syntax'
            else
                atom, nextCursor = { kind = 'literal', value = character:byte() }, cursor + 1
            end
            if not atom then return nil, parseError or 'pattern atom is invalid' end

            local minimum, maximum, quantifiedCursor, quantifierError = parsePatternQuantifier(pattern, nextCursor)
            if minimum == nil then return nil, quantifierError end
            tokens[#tokens + 1] = { atom = atom, minimum = minimum, maximum = maximum }
            if #tokens > patternLimits.tokens then return nil, 'pattern contains too many tokens' end
            cursor = quantifiedCursor
        end

        local states = {}
        local unboundedTokens = 0
        for _, token in ipairs(tokens) do
            for _ = 1, token.minimum do states[#states + 1] = { atom = token.atom } end
            if token.maximum == nil then
                unboundedTokens = unboundedTokens + 1
                states[#states + 1] = { atom = token.atom, skip = true, loop = true }
            else
                for _ = token.minimum + 1, token.maximum do
                    states[#states + 1] = { atom = token.atom, skip = true }
                end
            end
            if #states > patternLimits.states then return nil, 'compiled pattern contains too many states' end
        end
        if unboundedTokens > patternLimits.unboundedTokens then
            return nil, 'pattern contains too many unbounded quantifiers'
        end
        if not anchoredStart and #states > patternLimits.unanchoredStates then
            return nil, 'unanchored pattern contains too many states'
        end
        return {
            anchoredStart = anchoredStart,
            anchoredEnd = anchoredEnd,
            states = states,
            accept = #states + 1
        }, nil
    end

    local function cachedPattern(pattern)
        if type(pattern) ~= 'string' then return nil, 'pattern must be a bounded string' end
        local cached = patternCache[pattern]
        if cached then return cached.compiled, cached.error end
        local compiled, compileError = compilePattern(pattern)
        if #patternCacheOrder >= patternLimits.cache then
            local evicted = table.remove(patternCacheOrder, 1)
            patternCache[evicted] = nil
        end
        patternCacheOrder[#patternCacheOrder + 1] = pattern
        patternCache[pattern] = { compiled = compiled, error = compileError }
        return compiled, compileError
    end

    local function decodeUtf8(value, collect)
        local output = collect and {} or nil
        local count = 0
        local index = 1
        while index <= #value do
            local first = value:byte(index)
            local codepoint, width
            if first <= 0x7f then
                codepoint, width = first, 1
            elseif first >= 0xc2 and first <= 0xdf then
                local second = value:byte(index + 1)
                if not second or second < 0x80 or second > 0xbf then return nil end
                codepoint = (first & 0x1f) << 6 | (second & 0x3f)
                width = 2
            elseif first >= 0xe0 and first <= 0xef then
                local second, third = value:byte(index + 1), value:byte(index + 2)
                if not second or not third or second < 0x80 or second > 0xbf or third < 0x80 or third > 0xbf
                    or (first == 0xe0 and second < 0xa0) or (first == 0xed and second > 0x9f) then return nil end
                codepoint = (first & 0x0f) << 12 | (second & 0x3f) << 6 | (third & 0x3f)
                width = 3
            elseif first >= 0xf0 and first <= 0xf4 then
                local second, third, fourth = value:byte(index + 1), value:byte(index + 2), value:byte(index + 3)
                if not second or not third or not fourth or second < 0x80 or second > 0xbf
                    or third < 0x80 or third > 0xbf or fourth < 0x80 or fourth > 0xbf
                    or (first == 0xf0 and second < 0x90) or (first == 0xf4 and second > 0x8f) then return nil end
                codepoint = (first & 0x07) << 18 | (second & 0x3f) << 12
                    | (third & 0x3f) << 6 | (fourth & 0x3f)
                width = 4
            else
                return nil
            end
            count = count + 1
            if output then output[count] = codepoint end
            index = index + width
        end
        return output or count
    end

    local function patternMatches(compiled, value, decoded)
        local codepoints = decoded or decodeUtf8(value, true)
        if not codepoints then return false, nil end
        local states = compiled.states
        local work = 0
        local function spend(amount)
            work = work + (amount or 1)
            return work <= patternLimits.matchWork
        end
        local function addClosure(target, stateIndex)
            while not target[stateIndex] do
                if not spend(1) then return nil end
                target[stateIndex] = true
                local state = states[stateIndex]
                if not state or not state.skip then break end
                stateIndex = stateIndex + 1
            end
            return true
        end
        local function acceptsAt(position)
            return not compiled.anchoredEnd or position == #codepoints
        end

        local current = {}
        for position = 0, #codepoints do
            if position == 0 or not compiled.anchoredStart then
                if not addClosure(current, 1) then return nil, 'workBudget' end
            end
            if current[compiled.accept] and acceptsAt(position) then return true, nil end
            if position == #codepoints then break end
            local nextStates = {}
            local codepoint = codepoints[position + 1]
            for stateIndex in pairs(current) do
                if not spend(1) then return nil, 'workBudget' end
                local state = states[stateIndex]
                if state then
                    local atom = state.atom
                    local matched = atom.kind == 'literal' and atom.value == codepoint
                    if atom.kind == 'dot' then
                        matched = codepoint ~= 0x0a and codepoint ~= 0x0d
                            and codepoint ~= 0x2028 and codepoint ~= 0x2029
                    elseif atom.kind == 'class' then
                        matched = atom.characters[codepoint] == true
                        if atom.negate then matched = not matched end
                    end
                    if matched and not addClosure(nextStates, state.loop and stateIndex or stateIndex + 1) then
                        return nil, 'workBudget'
                    end
                end
            end
            current = nextStates
        end
        return false, nil
    end

    local function validatePattern(pattern)
        local compiled, compileError = cachedPattern(pattern)
        if compiled then return true, nil end
        return nil, {
            rule = 'unsupportedPattern',
            message = 'pattern is outside the supported bounded ECMAScript subset',
            details = { reason = compileError }
        }
    end

    local function inspectRuntimeValue(value, path, depth, shared)
        if not spendWork(shared, 1) then
            return nil, { path = path, rule = 'validationBudget', message = 'validation work budget exceeded' }
        end
        local function addBytes(amount)
            shared.bytes = (shared.bytes or 0) + amount
            return shared.maximumBytes == nil or shared.bytes <= shared.maximumBytes
        end
        local kind = type(value)
        if kind == 'nil' or kind == 'boolean' then
            if not addBytes(5) then
                return nil, { path = path, rule = 'payloadLimit', message = 'payload exceeds its aggregate byte limit' }
            end
            return true, nil
        end
        if kind == 'string' then
            if #value > shared.maximumStringBytes or not addBytes(#value + 2) then
                return nil, { path = path, rule = 'payloadLimit', message = 'string exceeds the protocol byte limit' }
            end
            if decodeUtf8(value, false) == nil then
                return nil, { path = path, rule = 'utf8', message = 'string must contain valid UTF-8' }
            end
            return true, nil
        end
        if kind == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then
                return nil, { path = path, rule = 'finite', message = 'number must be finite' }
            end
            if not addBytes(32) then
                return nil, { path = path, rule = 'payloadLimit', message = 'payload exceeds its aggregate byte limit' }
            end
            return true, nil
        end
        local containerKind = kind == 'table'
            and foundation.jsonContainerKind(value) or nil
        if kind ~= 'table' or not containerKind then
            return nil, { path = path, rule = 'plainJson', message = 'payload must contain plain JSON-compatible values' }
        end
        if depth > shared.maximumDepth then
            return nil, { path = path, rule = 'maxDepth', message = 'maximum nesting depth exceeded' }
        end
        if shared.active[value] then
            return nil, { path = path, rule = 'cycle', message = 'cyclic payload tables are not supported' }
        end
        if not addBytes(2) then
            return nil, { path = path, rule = 'payloadLimit', message = 'payload exceeds its aggregate byte limit' }
        end
        shared.active[value] = true
        local entries = {}
        local keyType, maximumIndex, count = nil, 0, 0
        for key, child in next, value do
            if not spendWork(shared, 1) then
                shared.active[value] = nil
                return nil, { path = path, rule = 'validationBudget', message = 'validation work budget exceeded' }
            end
            local currentType = type(key)
            if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                maximumIndex = math.max(maximumIndex, key)
            elseif currentType ~= 'string' then
                shared.active[value] = nil
                return nil, { path = path, rule = 'propertyName', message = 'payload keys must be strings or dense array indexes' }
            elseif #key > shared.maximumStringBytes or decodeUtf8(key, false) == nil
                or not addBytes(#key + 3) then
                shared.active[value] = nil
                return nil, { path = path, rule = 'propertyName', message = 'payload property names must be bounded valid UTF-8' }
            end
            if keyType and keyType ~= currentType then
                shared.active[value] = nil
                return nil, { path = path, rule = 'tableShape', message = 'payload tables cannot mix object and array keys' }
            end
            keyType = currentType
            count = count + 1
            shared.keys = shared.keys + 1
            if shared.keys > shared.maximumKeys then
                shared.active[value] = nil
                return nil, { path = path, rule = 'payloadLimit', message = 'payload contains too many table entries' }
            end
            entries[#entries + 1] = { key = key, value = child }
        end
        if keyType == 'number' and maximumIndex ~= count
            or containerKind == 'object' and keyType == 'number'
            or containerKind == 'array' and keyType == 'string' then
            shared.active[value] = nil
            return nil, { path = path, rule = 'arrayShape', message = 'payload arrays must be dense' }
        end
        for _, entry in ipairs(entries) do
            local childPath = keyType == 'string'
                and path .. '.' .. entry.key or ('%s[%d]'):format(path, entry.key)
            local valid, finding = inspectRuntimeValue(entry.value, childPath, depth + 1, shared)
            if not valid then shared.active[value] = nil return nil, finding end
        end
        shared.active[value] = nil
        return true, nil
    end

    local function validate(schema, value, path, state)
        schema = schema or {}
        path = path or '$'
        if not state then
            local shared = {
                active = {}, keys = 0, work = 0, workLimit = validationLimits.work,
                maximumDepth = protocol.limits.tableDepth or 12,
                maximumKeys = protocol.limits.tableKeys or 512,
                maximumStringBytes = protocol.limits.stringBytes or 16384
            }
            local compatible, compatibilityFinding = inspectRuntimeValue(value, path, 1, shared)
            if not compatible then return nil, compatibilityFinding end
            state = { depth = 0, shared = shared }
        end
        local shared = state.shared
        if not spendWork(shared, 1) then
            return nil, { path = path, rule = 'validationBudget', message = 'validation work budget exceeded' }
        end
        state.depth = state.depth + 1
        if state.depth > (protocol.limits.tableDepth or 12) then
            state.depth = state.depth - 1
            return nil, { path = path, rule = 'maxDepth', message = 'maximum nesting depth exceeded' }
        end

        if schema.const ~= nil then
            local same, comparisonError = equals(schema.const, value, shared)
            if comparisonError == 'workBudget' then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'validationBudget', message = 'validation work budget exceeded' }
            end
            if not same then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'const', message = 'value does not equal the required constant' }
            end
        end
        if type(schema.enum) == 'table' then
            local found = false
            for _, candidate in ipairs(schema.enum) do
                local same, comparisonError = equals(candidate, value, shared)
                if comparisonError == 'workBudget' then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'validationBudget', message = 'validation work budget exceeded' }
                end
                if same then found = true break end
            end
            if not found then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'enum', message = 'value is not an allowed enum member' }
            end
        end
        for _, keyword in ipairs({ 'oneOf', 'anyOf' }) do
            if type(schema[keyword]) == 'table' then
                local matches = 0
                for _, candidate in ipairs(schema[keyword]) do
                    local candidateState = { depth = state.depth - 1, shared = shared }
                    local candidateValid, candidateFinding = validate(candidate, value, path, candidateState)
                    if candidateFinding and (candidateFinding.rule == 'validationBudget'
                        or candidateFinding.rule == 'patternBudget') then
                        state.depth = state.depth - 1
                        return nil, candidateFinding
                    end
                    if candidateValid then matches = matches + 1 end
                end
                if matches == 0 or (keyword == 'oneOf' and matches ~= 1) then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = keyword, message = 'value does not match the alternatives' }
                end
            end
        end

        local expected = schema.type
        if type(expected) == 'table' then
            local matched = false
            for _, candidate in ipairs(expected) do
                local candidateMatched = candidate == valueType(value)
                    or (candidate == 'number' and type(value) == 'number')
                if candidate == 'array' then candidateMatched = type(value) == 'table' and arrayLength(value) ~= nil end
                if candidate == 'object' then
                    candidateMatched = type(value) == 'table'
                        and foundation.jsonContainerKind(value) ~= 'array'
                        and (next(value) == nil or arrayLength(value) == nil)
                end
                if candidateMatched then matched = true break end
            end
            if not matched then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'type', message = 'value has the wrong type' }
            end
        elseif expected then
            local actual = valueType(value)
            local matched = actual == expected or (expected == 'number' and type(value) == 'number')
            if expected == 'array' then matched = type(value) == 'table' and arrayLength(value) ~= nil end
            if expected == 'object' then
                matched = type(value) == 'table'
                    and foundation.jsonContainerKind(value) ~= 'array'
                    and (next(value) == nil or arrayLength(value) == nil)
            end
            if not matched then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'type', message = ('expected %s, received %s'):format(expected, actual) }
            end
        end

        if type(value) == 'string' then
            local byteLength = #value
            if byteLength > (protocol.limits.stringBytes or 16384) then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'payloadLimit', message = 'string exceeds the protocol byte limit' }
            end
            local decoded = decodeUtf8(value, schema.pattern ~= nil)
            if decoded == nil then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'utf8', message = 'string must contain valid UTF-8' }
            end
            local length = type(decoded) == 'table' and #decoded or decoded
            if schema.minLength and length < schema.minLength then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'minLength', message = 'string is too short' }
            end
            if schema.maxLength and length > schema.maxLength then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'maxLength', message = 'string is too long' }
            end
            if schema.pattern ~= nil then
                local compiled, compileError = cachedPattern(schema.pattern)
                if not compiled then
                    state.depth = state.depth - 1
                    return nil, {
                        path = path,
                        rule = 'unsupportedPattern',
                        message = 'schema pattern is outside the supported bounded ECMAScript subset',
                        details = { reason = compileError }
                    }
                end
                local matched, matchError = patternMatches(compiled, value, type(decoded) == 'table' and decoded or nil)
                if matchError == 'workBudget' then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'patternBudget', message = 'pattern work budget exceeded' }
                end
                if not matched then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'pattern', message = 'string does not match the required pattern' }
                end
            end
        elseif type(value) == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'finite', message = 'number must be finite' }
            end
            if schema.minimum and value < schema.minimum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'minimum', message = 'number is below the minimum' }
            end
            if schema.maximum and value > schema.maximum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'maximum', message = 'number exceeds the maximum' }
            end
            if schema.exclusiveMinimum and value <= schema.exclusiveMinimum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'exclusiveMinimum', message = 'number must be greater than the minimum' }
            end
            if schema.exclusiveMaximum and value >= schema.exclusiveMaximum then
                state.depth = state.depth - 1
                return nil, { path = path, rule = 'exclusiveMaximum', message = 'number must be less than the maximum' }
            end
        elseif type(value) == 'table' then
            local length = arrayLength(value)
            local expectsArray = expected == 'array'
            local expectsObject = expected == 'object'
            if type(expected) == 'table' then
                for _, candidate in ipairs(expected) do
                    if candidate == 'array' then expectsArray = true end
                    if candidate == 'object' then expectsObject = true end
                end
            end
            local hasArrayAssertions = schema.items ~= nil or schema.minItems ~= nil
                or schema.maxItems ~= nil or schema.uniqueItems ~= nil
            local hasObjectAssertions = schema.properties ~= nil or schema.required ~= nil
                or schema.additionalProperties ~= nil
            local validateAsArray = length ~= nil and (
                (expectsArray and not expectsObject)
                or (length > 0 and (expectsArray or not expectsObject))
                or (length == 0 and hasArrayAssertions and not hasObjectAssertions)
            )
            if validateAsArray then
                length = length or 0
                if schema.minItems and length < schema.minItems then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'minItems', message = 'array is too short' }
                end
                if schema.maxItems and length > schema.maxItems then
                    state.depth = state.depth - 1
                    return nil, { path = path, rule = 'maxItems', message = 'array is too long' }
                end
                if schema.uniqueItems == true then
                    if length > validationLimits.uniqueItems then
                        state.depth = state.depth - 1
                        return nil, { path = path, rule = 'validationBudget',
                            message = 'uniqueItems exceeds the bounded runtime limit' }
                    end
                    for left = 1, length do
                        for right = left + 1, length do
                            local same, comparisonError = equals(
                                rawget(value, left), rawget(value, right), shared)
                            if comparisonError == 'workBudget' then
                                state.depth = state.depth - 1
                                return nil, { path = path, rule = 'validationBudget',
                                    message = 'validation work budget exceeded' }
                            end
                            if same then
                                state.depth = state.depth - 1
                                return nil, { path = path, rule = 'uniqueItems', message = 'array items must be unique' }
                            end
                        end
                    end
                end
                if schema.items ~= nil then
                    for index = 1, length do
                        local ok, err = validate(schema.items, rawget(value, index),
                            ('%s[%d]'):format(path, index), state)
                        if not ok then state.depth = state.depth - 1 return nil, err end
                    end
                end
            else
                local required = {}
                for _, key in ipairs(schema.required or {}) do required[key] = true end
                for key in pairs(required) do
                    if rawget(value, key) == nil then
                        state.depth = state.depth - 1
                        return nil, { path = path .. '.' .. key, rule = 'required', message = 'required property is missing' }
                    end
                end
                for key, item in next, value do
                    if not spendWork(shared, 1) then
                        state.depth = state.depth - 1
                        return nil, { path = path, rule = 'validationBudget', message = 'validation work budget exceeded' }
                    end
                    if type(key) ~= 'string' then
                        state.depth = state.depth - 1
                        return nil, { path = path, rule = 'propertyName', message = 'object properties must be strings' }
                    end
                    local propertySchema = schema.properties and schema.properties[key]
                    if not propertySchema and schema.additionalProperties == false then
                        state.depth = state.depth - 1
                        return nil, { path = path .. '.' .. key, rule = 'additionalProperties', message = 'unknown property is not allowed' }
                    end
                    if propertySchema then
                        local ok, err = validate(propertySchema, item, path .. '.' .. key, state)
                        if not ok then state.depth = state.depth - 1 return nil, err end
                    end
                end
            end
        end
        state.depth = state.depth - 1
        return true, nil
    end

    local contractsByName = {}
    local contractCount = 0
    local contractNameCount = 0
    local contractBytes = 0
    local contractCountsByProvider = {}
    local contractBytesByProvider = {}
    local contractCountsByName = {}
    local function boundedRegistryLimit(value, fallback, maximum)
        if type(value) ~= 'number' or math.type(value) ~= 'integer'
            or value < 1 or value > maximum then return fallback end
        return value
    end
    local maximumContracts = boundedRegistryLimit(deps.maximumContracts, 4096, 16384)
    local maximumContractsPerProvider = boundedRegistryLimit(
        deps.maximumContractsPerProvider, 512, 4096)
    local maximumVersionsPerName = boundedRegistryLimit(
        deps.maximumVersionsPerName, 32, 256)
    local maximumContractBytes = boundedRegistryLimit(
        deps.maximumContractBytes, 64 * 1024 * 1024, 256 * 1024 * 1024)
    local maximumContractBytesPerProvider = boundedRegistryLimit(
        deps.maximumContractBytesPerProvider, 8 * 1024 * 1024, 64 * 1024 * 1024)
    local maximumContractDefinitionBytes = boundedRegistryLimit(
        deps.maximumContractDefinitionBytes, 128 * 1024, 512 * 1024)
    local registry = {}
    local contractFields = {
        name = true, version = true, kind = true, provider = true, stability = true,
        network = true, capability = true, sessionStates = true, input = true,
        output = true, errors = true, idempotent = true, rateLimit = true,
        deprecatedSince = true, replacement = true, domain = true, major = true
    }
    local contractKinds = { rpc = true, event = true, hook = true, service = true }
    local contractStabilities = {
        experimental = true, stable = true, deprecated = true, internal = true
    }
    local contractNetworks = {
        none = true, ['client-to-server'] = true, ['server-to-client'] = true
    }
    local contractSessionStates = {
        CONNECTING = true, AUTHENTICATING = true, AUTHENTICATED = true,
        SELECTING_CHARACTER = true, LOADING_CHARACTER = true, ACTIVE = true,
        UNLOADING_CHARACTER = true, DISCONNECTING = true, CLOSED = true
    }

    local function validContractName(value, maximumBytes)
        if type(value) ~= 'string' or #value < 1 or #value > maximumBytes then return false end
        if not value:sub(1, 1):match('^[a-z]$') then return false end
        local previousSeparator = false
        for index = 2, #value do
            local character = value:sub(index, index)
            local alphanumeric = character:match('^[a-z0-9]$') ~= nil
            local separator = character == '.' or character == '_' or character == '-'
            if not alphanumeric and not separator then return false end
            if separator and previousSeparator then return false end
            previousSeparator = separator
        end
        return not previousSeparator
    end

    local function validProvider(value)
        if type(value) ~= 'string' or #value > 64 or value:sub(1, 6) ~= 'synex_' then return false end
        local suffix = value:sub(7)
        return #suffix > 0 and suffix:match('^[a-z0-9_]+$') ~= nil
    end

    local function validErrorCode(value)
        return type(value) == 'string' and #value >= 2 and #value <= 64
            and value:match('^[A-Z][A-Z0-9_]+$') ~= nil
    end

    local function validRequestedVersion(value)
        if type(value) ~= 'string' or #value < 1 or #value > 128 then return false end
        if foundation.semver(value) then return true end
        if value == '*' then return true end
        if value:find('[^0-9%.%^~<>= ]') then return false end
        local supportedOperators = {
            [''] = true, ['^'] = true, ['~'] = true, ['>'] = true,
            ['>='] = true, ['<'] = true, ['<='] = true, ['='] = true
        }
        local count = 0
        for token in value:gmatch('%S+') do
            count = count + 1
            if count > 8 then return false end
            local operator, target = token:match('^([%^~<>=]*)(%d+%.%d+%.%d+)$')
            if not target or not supportedOperators[operator] or not foundation.semver(target) then return false end
        end
        return count > 0
    end

    local function validateSchemaDefinition(schema, requestedLimits)
        requestedLimits = type(requestedLimits) == 'table' and getmetatable(requestedLimits) == nil
            and requestedLimits or {}
        local function boundedLimit(value, fallback, maximum)
            value = tonumber(value)
            if not value or value ~= value or value == math.huge or value == -math.huge then value = fallback end
            return math.min(math.max(math.floor(value), 1), maximum)
        end
        local maximumDepth = boundedLimit(requestedLimits.maximumDepth, 24, 24)
        local maximumKeys = boundedLimit(requestedLimits.maximumKeys, 2048, 2048)
        local maximumStringBytes = boundedLimit(requestedLimits.maximumStringBytes, 32768, 32768)
        local inspected = {
            active = {}, keys = 0, work = 0, workLimit = validationLimits.schemaWork
        }

        local function finding(path, rule, message, details)
            return { path = path, rule = rule, message = message, details = details }
        end
        local function inspectJson(value, path, depth)
            if not spendWork(inspected, 1) then
                return nil, finding(path, 'workBudget', 'schema validation work budget exceeded')
            end
            local kind = type(value)
            if kind == 'string' then
                if #value > maximumStringBytes then
                    return nil, finding(path, 'maximumBytes', 'schema string exceeds the supported byte limit')
                end
                if decodeUtf8(value, false) == nil then
                    return nil, finding(path, 'utf8', 'schema strings must contain valid UTF-8')
                end
                return true, nil
            end
            if kind == 'number' then
                if value ~= value or value == math.huge or value == -math.huge then
                    return nil, finding(path, 'finite', 'schema numbers must be finite')
                end
                return true, nil
            end
            if kind == 'boolean' then return true, nil end
            if kind ~= 'table' or getmetatable(value) ~= nil then
                return nil, finding(path, 'jsonType', 'schema values must be plain JSON-compatible values')
            end
            if depth > maximumDepth then return nil, finding(path, 'maxDepth', 'schema nesting exceeds the supported limit') end
            if inspected.active[value] then return nil, finding(path, 'cycle', 'cyclic schemas are not supported') end
            inspected.active[value] = true
            local keyType, maximumIndex, count = nil, 0, 0
            for key, child in pairs(value) do
                if not spendWork(inspected, 1) then
                    inspected.active[value] = nil
                    return nil, finding(path, 'workBudget', 'schema validation work budget exceeded')
                end
                local currentType = type(key)
                if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentType ~= 'string' then
                    inspected.active[value] = nil
                    return nil, finding(path, 'propertyName', 'schema table keys must be strings or dense array indexes')
                elseif #key > maximumStringBytes or decodeUtf8(key, false) == nil then
                    inspected.active[value] = nil
                    return nil, finding(path, 'propertyName', 'schema property names must be bounded valid UTF-8')
                end
                if keyType and keyType ~= currentType then
                    inspected.active[value] = nil
                    return nil, finding(path, 'tableShape', 'schema tables cannot mix object and array keys')
                end
                keyType = currentType
                count = count + 1
                inspected.keys = inspected.keys + 1
                if inspected.keys > maximumKeys then
                    inspected.active[value] = nil
                    return nil, finding(path, 'maximumKeys', 'schema contains too many entries')
                end
                local childPath = currentType == 'string'
                    and path .. '.' .. key or ('%s[%d]'):format(path, key)
                local valid, childFinding = inspectJson(child, childPath, depth + 1)
                if not valid then inspected.active[value] = nil return nil, childFinding end
            end
            inspected.active[value] = nil
            if keyType == 'number' and maximumIndex ~= count then
                return nil, finding(path, 'arrayShape', 'schema arrays must be dense')
            end
            return true, nil
        end

        local inspectedOk, inspectionFinding = inspectJson(schema, '$', 1)
        if not inspectedOk then return nil, inspectionFinding end
        local active = {}
        local function validateNode(node, path, depth)
            if not spendWork(inspected, 1) then
                return nil, finding(path, 'workBudget', 'schema validation work budget exceeded')
            end
            if type(node) ~= 'table' then return nil, finding(path, 'type', 'schema nodes must be objects') end
            if depth > maximumDepth then return nil, finding(path, 'maxDepth', 'schema nesting exceeds the supported limit') end
            if active[node] then return nil, finding(path, 'cycle', 'cyclic schemas are not supported') end
            active[node] = true
            for key in pairs(node) do
                if type(key) ~= 'string' or not supportedSchemaKeywords[key] then
                    active[node] = nil
                    return nil, finding(path .. '.' .. tostring(key), 'unsupportedKeyword',
                        'schema keyword is not implemented by the Core runtime')
                end
            end

            local expected = node.type
            if expected ~= nil then
                if type(expected) == 'string' then
                    if not supportedSchemaTypes[expected] then
                        active[node] = nil
                        return nil, finding(path .. '.type', 'enum', 'schema type is not supported')
                    end
                elseif type(expected) == 'table' then
                    local length = arrayLength(expected)
                    if not length or length < 1 or length > 7 then
                        active[node] = nil
                        return nil, finding(path .. '.type', 'arrayShape', 'schema type alternatives must be a bounded dense array')
                    end
                    local seen = {}
                    for index = 1, length do
                        local candidate = expected[index]
                        if type(candidate) ~= 'string' or not supportedSchemaTypes[candidate] or seen[candidate] then
                            active[node] = nil
                            return nil, finding(('%s.type[%d]'):format(path, index), 'enum',
                                'schema type alternatives must be unique supported types')
                        end
                        seen[candidate] = true
                    end
                else
                    active[node] = nil
                    return nil, finding(path .. '.type', 'type', 'schema type must be a string or array')
                end
            end

            for _, keyword in ipairs({ 'minLength', 'maxLength', 'minItems', 'maxItems' }) do
                local value = node[keyword]
                if value ~= nil and (type(value) ~= 'number' or math.type(value) ~= 'integer' or value < 0) then
                    active[node] = nil
                    return nil, finding(path .. '.' .. keyword, 'type', keyword .. ' must be a non-negative integer')
                end
            end
            if (node.minLength or 0) > (protocol.limits.stringBytes or 16384)
                or (node.maxLength or 0) > (protocol.limits.stringBytes or 16384) then
                active[node] = nil
                return nil, finding(path, 'maximum', 'string length constraints exceed the protocol limit')
            end
            if (node.minItems or 0) > (protocol.limits.tableKeys or 512)
                or (node.maxItems or 0) > (protocol.limits.tableKeys or 512) then
                active[node] = nil
                return nil, finding(path, 'maximum', 'array length constraints exceed the protocol limit')
            end
            if node.minLength and node.maxLength and node.minLength > node.maxLength then
                active[node] = nil
                return nil, finding(path, 'range', 'minLength cannot exceed maxLength')
            end
            if node.minItems and node.maxItems and node.minItems > node.maxItems then
                active[node] = nil
                return nil, finding(path, 'range', 'minItems cannot exceed maxItems')
            end
            for _, keyword in ipairs({ 'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum' }) do
                local value = node[keyword]
                if value ~= nil and (type(value) ~= 'number' or value ~= value
                    or value == math.huge or value == -math.huge) then
                    active[node] = nil
                    return nil, finding(path .. '.' .. keyword, 'type', keyword .. ' must be a finite number')
                end
            end
            if node.minimum and node.maximum and node.minimum > node.maximum then
                active[node] = nil
                return nil, finding(path, 'range', 'minimum cannot exceed maximum')
            end
            if node.exclusiveMinimum and node.exclusiveMaximum
                and node.exclusiveMinimum >= node.exclusiveMaximum then
                active[node] = nil
                return nil, finding(path, 'range', 'exclusiveMinimum must be lower than exclusiveMaximum')
            end
            if node.additionalProperties ~= nil and type(node.additionalProperties) ~= 'boolean' then
                active[node] = nil
                return nil, finding(path .. '.additionalProperties', 'type',
                    'additionalProperties schemas are not supported by the Core runtime')
            end
            if node.uniqueItems ~= nil and type(node.uniqueItems) ~= 'boolean' then
                active[node] = nil
                return nil, finding(path .. '.uniqueItems', 'type', 'uniqueItems must be a boolean')
            end
            if node.uniqueItems == true and (node.maxItems == nil
                or node.maxItems > validationLimits.uniqueItems) then
                active[node] = nil
                return nil, finding(path .. '.uniqueItems', 'maximum',
                    ('uniqueItems requires maxItems at or below %d'):format(validationLimits.uniqueItems))
            end
            for _, keyword in ipairs({ 'deprecated', 'readOnly', 'writeOnly' }) do
                if node[keyword] ~= nil and type(node[keyword]) ~= 'boolean' then
                    active[node] = nil
                    return nil, finding(path .. '.' .. keyword, 'type', keyword .. ' must be a boolean annotation')
                end
            end
            for _, keyword in ipairs({ '$schema', '$id', '$comment', 'title', 'description' }) do
                if node[keyword] ~= nil and type(node[keyword]) ~= 'string' then
                    active[node] = nil
                    return nil, finding(path .. '.' .. keyword, 'type', keyword .. ' must be a string annotation')
                end
            end
            if node.examples ~= nil and arrayLength(node.examples) == nil then
                active[node] = nil
                return nil, finding(path .. '.examples', 'arrayShape', 'examples must be a dense array annotation')
            end
            if node.pattern ~= nil then
                local valid, patternFinding = validatePattern(node.pattern)
                if not valid then
                    active[node] = nil
                    patternFinding.path = path .. '.pattern'
                    return nil, patternFinding
                end
            end
            if node.required ~= nil then
                local length = arrayLength(node.required)
                if not length or length > (protocol.limits.tableKeys or 512) then
                    active[node] = nil
                    return nil, finding(path .. '.required', 'arrayShape', 'required must be a bounded dense array')
                end
                local seen = {}
                for index = 1, length do
                    local property = node.required[index]
                    if type(property) ~= 'string' or #property < 1 or seen[property] then
                        active[node] = nil
                        return nil, finding(('%s.required[%d]'):format(path, index), 'propertyName',
                            'required properties must be unique non-empty strings')
                    end
                    seen[property] = true
                end
            end
            if node.enum ~= nil then
                local length = arrayLength(node.enum)
                if not length or length < 1 or length > 256 then
                    active[node] = nil
                    return nil, finding(path .. '.enum', 'arrayShape', 'enum must be a non-empty bounded dense array')
                end
                for left = 1, length do
                    for right = left + 1, length do
                        local same, comparisonError = equals(node.enum[left], node.enum[right], inspected)
                        if comparisonError == 'workBudget' then
                            active[node] = nil
                            return nil, finding(path .. '.enum', 'workBudget',
                                'schema validation work budget exceeded')
                        end
                        if same then
                            active[node] = nil
                            return nil, finding(path .. '.enum', 'uniqueItems', 'enum values must be unique')
                        end
                    end
                end
            end
            for _, keyword in ipairs({ 'oneOf', 'anyOf' }) do
                local alternatives = node[keyword]
                if alternatives ~= nil then
                    local length = arrayLength(alternatives)
                    if not length or length < 1 or length > 32 then
                        active[node] = nil
                        return nil, finding(path .. '.' .. keyword, 'arrayShape',
                            keyword .. ' must contain between 1 and 32 schema objects')
                    end
                    for index = 1, length do
                        local valid, childFinding = validateNode(
                            alternatives[index], ('%s.%s[%d]'):format(path, keyword, index), depth + 1)
                        if not valid then active[node] = nil return nil, childFinding end
                    end
                end
            end
            if node.items ~= nil then
                local valid, childFinding = validateNode(node.items, path .. '.items', depth + 1)
                if not valid then active[node] = nil return nil, childFinding end
            end
            if node.properties ~= nil then
                if type(node.properties) ~= 'table' or getmetatable(node.properties) ~= nil then
                    active[node] = nil
                    return nil, finding(path .. '.properties', 'type', 'properties must be an object')
                end
                for property, child in pairs(node.properties) do
                    if type(property) ~= 'string' or #property < 1 then
                        active[node] = nil
                        return nil, finding(path .. '.properties', 'propertyName',
                            'property schema names must be non-empty strings')
                    end
                    local valid, childFinding = validateNode(child, path .. '.properties.' .. property, depth + 1)
                    if not valid then active[node] = nil return nil, childFinding end
                end
            end
            active[node] = nil
            return true, nil
        end
        return validateNode(schema, '$', 1)
    end

    local function validateDefinition(contract)
        if type(contract) ~= 'table' or getmetatable(contract) ~= nil then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract definition must be a plain object.')
        end
        local contractInspection = {
            active = {}, keys = 0, work = 0, workLimit = validationLimits.schemaWork,
            maximumDepth = 25, maximumKeys = 8192, maximumStringBytes = 32768,
            bytes = 0, maximumBytes = maximumContractDefinitionBytes
        }
        local compatible, compatibilityFinding = inspectRuntimeValue(contract, '$', 1, contractInspection)
        if not compatible then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract definition is not bounded plain JSON.', {
                details = compatibilityFinding
            })
        end
        for key in pairs(contract) do
            if not contractFields[key] then
                return nil, foundation.error('INVALID_CONTRACT', 'Contract definition contains an unsupported field.', {
                    details = { field = tostring(key) }
                })
            end
        end
        if not validContractName(contract.name, 128) or type(contract.version) ~= 'string'
            or #contract.version < 1 or #contract.version > 128 then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract name and version are invalid.')
        end
        local version = foundation.semver(contract.version)
        if not version then return nil, foundation.error('INVALID_CONTRACT_VERSION', 'Contract version must be semantic.') end
        if contract.major ~= nil and (type(contract.major) ~= 'number' or math.type(contract.major) ~= 'integer'
            or contract.major ~= version.major) then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract major does not match its semantic version.')
        end
        if not contractKinds[contract.kind] or not contractStabilities[contract.stability]
            or not contractNetworks[contract.network] or not validProvider(contract.provider) then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract kind, provider, stability, or network is invalid.')
        end
        if contract.domain ~= nil and not validContractName(contract.domain, 128) then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract domain is invalid.')
        end
        if contract.capability ~= nil and not validContractName(contract.capability, 128) then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract capability is invalid.')
        end
        if contract.replacement ~= nil and not validContractName(contract.replacement, 128) then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract replacement is invalid.')
        end
        if contract.deprecatedSince ~= nil and (type(contract.deprecatedSince) ~= 'string'
            or #contract.deprecatedSince > 128 or not foundation.semver(contract.deprecatedSince)) then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract deprecation version is invalid.')
        end
        if contract.idempotent ~= nil and type(contract.idempotent) ~= 'boolean' then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract idempotent must be a boolean.')
        end
        if type(contract.input) ~= 'table' or getmetatable(contract.input) ~= nil
            or type(contract.output) ~= 'table' or getmetatable(contract.output) ~= nil then
            return nil, foundation.error('INVALID_CONTRACT', 'Input and output schemas must be plain objects.')
        end
        local errorCount = arrayLength(contract.errors)
        if not errorCount or errorCount > 256 then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract errors must be a bounded dense array.')
        end
        local seenErrors = {}
        for index = 1, errorCount do
            local code = contract.errors[index]
            if not validErrorCode(code) or seenErrors[code] then
                return nil, foundation.error('INVALID_CONTRACT', 'Contract error codes must be unique and valid.', {
                    details = { index = index }
                })
            end
            seenErrors[code] = true
        end
        if contract.sessionStates ~= nil then
            local stateCount = arrayLength(contract.sessionStates)
            if not stateCount or stateCount > 9 then
                return nil, foundation.error('INVALID_CONTRACT', 'Contract session states must be a bounded dense array.')
            end
            local seenStates = {}
            for index = 1, stateCount do
                local sessionState = contract.sessionStates[index]
                if not contractSessionStates[sessionState] or seenStates[sessionState] then
                    return nil, foundation.error('INVALID_CONTRACT', 'Contract session states must be unique supported values.', {
                        details = { index = index }
                    })
                end
                seenStates[sessionState] = true
            end
        end
        if contract.rateLimit ~= nil then
            local rateLimit = contract.rateLimit
            if type(rateLimit) ~= 'table' or getmetatable(rateLimit) ~= nil
                or type(rateLimit.capacity) ~= 'number' or math.type(rateLimit.capacity) ~= 'integer'
                or rateLimit.capacity < 1 or rateLimit.capacity > 1000
                or type(rateLimit.refillPerSecond) ~= 'number'
                or rateLimit.refillPerSecond ~= rateLimit.refillPerSecond
                or rateLimit.refillPerSecond == math.huge
                or rateLimit.refillPerSecond == -math.huge or rateLimit.refillPerSecond <= 0
                or rateLimit.refillPerSecond > 1000 then
                return nil, foundation.error('INVALID_CONTRACT', 'Contract rate limit is invalid.')
            end
            for key in pairs(rateLimit) do
                if key ~= 'capacity' and key ~= 'refillPerSecond' then
                    return nil, foundation.error('INVALID_CONTRACT', 'Contract rate limit contains an unsupported field.')
                end
            end
        end
        local inputSchemaValid, inputSchemaError = validateSchemaDefinition(contract.input)
        if not inputSchemaValid then
            return nil, foundation.error('INVALID_CONTRACT_SCHEMA', 'Contract input schema is not supported by the Core runtime.', {
                details = inputSchemaError
            })
        end
        local outputSchemaValid, outputSchemaError = validateSchemaDefinition(contract.output)
        if not outputSchemaValid then
            return nil, foundation.error('INVALID_CONTRACT_SCHEMA', 'Contract output schema is not supported by the Core runtime.', {
                details = outputSchemaError
            })
        end
        return version, nil, contractInspection.bytes
    end

    function registry:register(contract)
        local version, err, footprint = validateDefinition(contract)
        if not version then return nil, err end
        local copied, stored = pcall(foundation.copy, contract)
        if not copied or type(stored) ~= 'table' then
            return nil, foundation.error('INVALID_CONTRACT', 'Contract definition could not be copied safely.')
        end
        stored.major = version.major
        local versions = contractsByName[contract.name]
        if versions and versions[contract.version] then
            local identical = equals(versions[contract.version], stored, {
                work = 0, workLimit = validationLimits.schemaWork
            })
            if identical ~= true then
                return nil, foundation.error('CONTRACT_DEFINITION_CONFLICT',
                    'The contract version is already registered with a different definition.', {
                        details = { name = contract.name, version = contract.version }
                    })
            end
            return foundation.copy(versions[contract.version]), nil
        end
        local versionsForName = contractCountsByName[stored.name] or 0
        local provider = stored.provider
        if contractCount >= maximumContracts
            or (contractCountsByProvider[provider] or 0) >= maximumContractsPerProvider
            or versionsForName >= maximumVersionsPerName
            or contractBytes + footprint > maximumContractBytes
            or (contractBytesByProvider[provider] or 0) + footprint
                > maximumContractBytesPerProvider then
            return nil, foundation.error('CONTRACT_REGISTRY_LIMIT',
                'The canonical contract registry capacity has been reached.', {
                    details = { provider = provider, name = stored.name }
                })
        end
        if not versions then
            versions = {}
            contractsByName[stored.name] = versions
            contractNameCount = contractNameCount + 1
        end
        versions[contract.version] = stored
        contractCount = contractCount + 1
        contractBytes = contractBytes + footprint
        contractCountsByProvider[provider] = (contractCountsByProvider[provider] or 0) + 1
        contractBytesByProvider[provider] = (contractBytesByProvider[provider] or 0) + footprint
        contractCountsByName[stored.name] = (contractCountsByName[stored.name] or 0) + 1
        return foundation.copy(stored), nil
    end

    function registry:resolve(name, requestedVersion)
        if not validContractName(name, 128) then
            return nil, foundation.error('INVALID_CONTRACT', 'The requested contract name is invalid.')
        end
        if not validRequestedVersion(requestedVersion) then
            return nil, foundation.error('INVALID_CONTRACT_VERSION', 'The requested contract version or range is invalid.')
        end
        local versions = contractsByName[name]
        if not versions then return nil, foundation.error('CONTRACT_NOT_FOUND', 'The requested contract does not exist.') end
        if versions[requestedVersion] then return foundation.copy(versions[requestedVersion]), nil end
        local best = nil
        for version, contract in pairs(versions) do
            if foundation.semverSatisfies(version, requestedVersion) then
                local candidateVersion = foundation.semver(version)
                local bestVersion = best and foundation.semver(best.version) or nil
                if not bestVersion or candidateVersion.major > bestVersion.major
                    or (candidateVersion.major == bestVersion.major and candidateVersion.minor > bestVersion.minor)
                    or (candidateVersion.major == bestVersion.major and candidateVersion.minor == bestVersion.minor
                        and candidateVersion.patch > bestVersion.patch) then
                    best = contract
                end
            end
        end
        if not best then return nil, foundation.error('CONTRACT_VERSION_UNAVAILABLE', 'No compatible contract version is registered.') end
        return foundation.copy(best), nil
    end

    function registry:validateInput(contract, value)
        local ok, finding = validate(contract.input, value)
        if not ok then
            return nil, foundation.error('VALIDATION_FAILED', 'The request does not match its contract.', { details = finding })
        end
        return true, nil
    end
    function registry:validateOutput(contract, value)
        local ok, finding = validate(contract.output, value)
        if not ok then
            return nil, foundation.error('INVALID_PROVIDER_RESPONSE', 'The provider returned an invalid response.', { details = finding })
        end
        return true, nil
    end
    function registry:list()
        local result = {}
        for _, versions in pairs(contractsByName) do
            for _, contract in pairs(versions) do result[#result + 1] = foundation.copy(contract) end
        end
        table.sort(result, function(a, b)
            if a.name == b.name then return a.version < b.version end
            return a.name < b.name
        end)
        return result
    end
    function registry:snapshot()
        return {
            contracts = contractCount,
            names = contractNameCount,
            bytes = contractBytes,
            maximumContracts = maximumContracts,
            maximumBytes = maximumContractBytes,
            providers = foundation.copy(contractCountsByProvider),
            providerBytes = foundation.copy(contractBytesByProvider)
        }
    end

    for _, contract in ipairs((deps.generated and deps.generated.contracts) or {}) do
        local registered, err = registry:register(contract)
        if not registered then error(('generated contract rejected: %s'):format(err.message)) end
    end

    return {
        registry = registry,
        validate = validate,
        validatePattern = validatePattern,
        validateSchemaDefinition = validateSchemaDefinition
    }
end
