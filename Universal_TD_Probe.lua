-- Universal TD Probe v2
-- Passive discovery in Normal/Brutal modes and loss-minimising transport/state
-- correlation in Perfect mode. The probe never calls a game remote itself.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local LogService = game:GetService("LogService")
local CollectionService = game:GetService("CollectionService")

local Environment = getgenv()
local previous = Environment.UniversalTDProbe
if previous and type(previous.Stop) == "function" then
    pcall(previous.Stop, "replaced")
end

local userConfig = type(Environment.UniversalTDProbeConfig) == "table"
    and Environment.UniversalTDProbeConfig
    or {}

local requestedMode = string.lower(tostring(userConfig.Mode or "Normal"))
local isBrutalPerfectRequest = requestedMode == "brutal_perfect"
    or requestedMode == "brutal-perfect"
    or requestedMode == "brutalperfect"
local selectedMode = isBrutalPerfectRequest and "Brutal_Perfect"
    or requestedMode == "perfect" and "Perfect"
    or requestedMode == "brutal" and "Brutal"
    or "Normal"
local isPerfect = selectedMode == "Perfect" or selectedMode == "Brutal_Perfect"
local isBrutal = selectedMode == "Brutal" or isPerfect

local Config = {
    Mode = selectedMode,
    Brutal = isBrutal,
    Perfect = isPerfect,
    Duration = math.max(60, tonumber(userConfig.Duration) or (isPerfect and 1800 or isBrutal and 3600 or 1800)),
    ScanInterval = math.max(0.15, tonumber(userConfig.ScanInterval) or (isPerfect and 0.25 or isBrutal and 0.35 or 0.75)),
    FlushInterval = math.max(0.5, tonumber(userConfig.FlushInterval) or 2),
    MaxEvents = math.max(1000, tonumber(userConfig.MaxEvents) or (isPerfect and 300000 or isBrutal and 200000 or 50000)),
    MaxTextLength = math.max(80, tonumber(userConfig.MaxTextLength) or 500),
    InputWindow = math.max(1, tonumber(userConfig.InputWindow) or 4),
    CorrelationWindow = math.max(1, tonumber(userConfig.CorrelationWindow) or 8),
    PreciseMaxDepth = math.max(3, tonumber(userConfig.PreciseMaxDepth) or 8),
    PreciseMaxItems = math.max(50, tonumber(userConfig.PreciseMaxItems) or 500),
    CaptureOutgoing = userConfig.CaptureOutgoing ~= false and isPerfect,
    CaptureCallingScript = userConfig.CaptureCallingScript ~= false,
    CaptureKeyboard = userConfig.CaptureKeyboard ~= false and isPerfect,
    Introspect = userConfig.Introspect == true,
}

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local StartedAt = os.clock()
local UnixStarted = os.time()
local BaseName = string.format("universal_td_probe_%s_%s", tostring(game.PlaceId), tostring(UnixStarted))
local JsonlFile = BaseName .. ".jsonl"
local SummaryFile = BaseName .. "_summary.json"
local CanWrite = type(writefile) == "function"
local CanAppend = type(appendfile) == "function"
local CanRead = type(readfile) == "function"

local Probe = {
    Running = true,
    EventCount = 0,
    Sequence = 0,
    ActionSequence = 0,
    DroppedEvents = 0,
    EncodeErrors = 0,
    WriteErrors = 0,
    EventTypes = {},
    Connections = {},
    Buffer = {},
    MemoryLines = {},
    LastInputAt = -math.huge,
    LastInput = nil,
    ActiveAction = nil,
    Transactions = {},
    TransactionOrder = {},
    LastRemote = nil,
    Hook = { enabled = false, available = false, state = "not_initialized" },
    RemoteCandidates = {},
    StateCandidates = {},
    WorldCandidates = {},
    GuiCandidates = {},
    LogicalObjects = setmetatable({}, { __mode = "k" }),
    LogicalSequence = 0,
    HookGeneration = tostring(os.clock()) .. ":" .. tostring(math.random()),
}
Environment.UniversalTDProbe = Probe

local Keywords = {
    place = { "place", "spawn", "deploy", "summon", "build" },
    upgrade = { "upgrade", "level", "rank", "evolve", "enhance", "max" },
    sell = { "sell", "remove", "delete", "refund" },
    target = { "target", "priority", "first", "last", "strong", "weak" },
    wave = { "wave", "round" },
    money = { "money", "cash", "coin", "gold", "yen", "credit", "currency" },
    ready = { "ready", "start", "vote" },
    replay = { "replay", "retry", "restart", "again" },
    lobby = { "lobby", "return", "leave", "back" },
    result = { "victory", "defeat", "win", "lost", "result", "gameended", "gameover" },
    speed = { "speed", "timescale", "scale" },
    skip = { "skip", "autoskip" },
    tower = { "tower", "unit", "troop", "defender" },
    enemy = { "enemy", "enemies", "mob", "toilet" },
    health = { "health", "hp", "lives", "base" },
    cost = { "cost", "price" },
    map = { "map", "chapter", "stage", "mode", "difficulty" },
}

local function clampText(value)
    local text = tostring(value or "")
    if #text > Config.MaxTextLength then
        return text:sub(1, Config.MaxTextLength) .. "..."
    end
    return text
end

local function safePath(instance)
    if typeof(instance) ~= "Instance" then
        return tostring(instance)
    end
    local parts = {}
    local current = instance
    local guard = 0
    while current and current ~= game and guard < 100 do
        table.insert(parts, 1, current.Name)
        current = current.Parent
        guard = guard + 1
    end
    return table.concat(parts, ".")
end

local function serialize(value, depth)
    depth = depth or 0
    if depth >= 4 then
        return clampText(value)
    end

    local valueType = typeof(value)
    if valueType == "nil" or valueType == "boolean" or valueType == "number" then
        return value
    elseif valueType == "string" then
        return clampText(value)
    elseif valueType == "Instance" then
        return {
            type = "Instance",
            class = value.ClassName,
            name = value.Name,
            path = safePath(value),
        }
    elseif valueType == "Vector3" then
        return { type = valueType, x = value.X, y = value.Y, z = value.Z }
    elseif valueType == "Vector2" then
        return { type = valueType, x = value.X, y = value.Y }
    elseif valueType == "CFrame" then
        return { type = "CFrame", components = { value:GetComponents() } }
    elseif valueType == "Color3" then
        return { type = "Color3", r = value.R, g = value.G, b = value.B }
    elseif valueType == "EnumItem" then
        return tostring(value)
    elseif valueType == "table" then
        local result = {}
        local count = 0
        for key, nested in pairs(value) do
            count = count + 1
            if count > 100 then
                result.__truncated = true
                break
            end
            result[tostring(key)] = serialize(nested, depth + 1)
        end
        return result
    end
    return clampText(value)
end

-- Remote arguments use an entry-list representation so numeric/string/table
-- keys, sparse arrays, explicit table.pack().n and repeated references survive.
local function serializePrecise(value, depth, state)
    depth = depth or 0
    state = state or { seen = {}, nextId = 0, items = 0 }
    local valueType = typeof(value)

    if valueType == "nil" then
        return { type = "nil" }
    elseif valueType == "boolean" or valueType == "string" then
        return value
    elseif valueType == "number" then
        if value ~= value then return { type = "number", value = "nan" } end
        if value == math.huge then return { type = "number", value = "+inf" } end
        if value == -math.huge then return { type = "number", value = "-inf" } end
        return value
    elseif valueType == "Instance" then
        local debugId
        pcall(function() debugId = value:GetDebugId(0) end)
        return {
            type = "Instance",
            class = value.ClassName,
            name = value.Name,
            path = safePath(value),
            debugId = debugId,
            logicalId = Probe.LogicalObjects[value] and Probe.LogicalObjects[value].id or nil,
        }
    elseif valueType == "Vector3" then
        return { type = valueType, x = value.X, y = value.Y, z = value.Z }
    elseif valueType == "Vector2" then
        return { type = valueType, x = value.X, y = value.Y }
    elseif valueType == "CFrame" then
        return { type = valueType, components = { value:GetComponents() } }
    elseif valueType == "Color3" then
        return { type = valueType, r = value.R, g = value.G, b = value.B }
    elseif valueType == "UDim" then
        return { type = valueType, scale = value.Scale, offset = value.Offset }
    elseif valueType == "UDim2" then
        return { type = valueType, xScale = value.X.Scale, xOffset = value.X.Offset, yScale = value.Y.Scale, yOffset = value.Y.Offset }
    elseif valueType == "Rect" then
        return { type = valueType, min = serializePrecise(value.Min), max = serializePrecise(value.Max) }
    elseif valueType == "Ray" then
        return { type = valueType, origin = serializePrecise(value.Origin), direction = serializePrecise(value.Direction) }
    elseif valueType == "NumberRange" then
        return { type = valueType, min = value.Min, max = value.Max }
    elseif valueType == "NumberSequence" then
        local keypoints = {}
        for _, point in ipairs(value.Keypoints) do
            table.insert(keypoints, { time = point.Time, value = point.Value, envelope = point.Envelope })
        end
        return { type = valueType, keypoints = keypoints }
    elseif valueType == "ColorSequence" then
        local keypoints = {}
        for _, point in ipairs(value.Keypoints) do
            table.insert(keypoints, { time = point.Time, color = serializePrecise(point.Value) })
        end
        return { type = valueType, keypoints = keypoints }
    elseif valueType == "TweenInfo" then
        return {
            type = valueType,
            time = value.Time,
            easingStyle = tostring(value.EasingStyle),
            easingDirection = tostring(value.EasingDirection),
            repeatCount = value.RepeatCount,
            reverses = value.Reverses,
            delayTime = value.DelayTime,
        }
    elseif valueType == "PhysicalProperties" then
        return {
            type = valueType,
            density = value.Density,
            friction = value.Friction,
            elasticity = value.Elasticity,
            frictionWeight = value.FrictionWeight,
            elasticityWeight = value.ElasticityWeight,
        }
    elseif valueType == "DateTime" then
        return { type = valueType, unixTimestampMillis = value.UnixTimestampMillis }
    elseif valueType == "BrickColor" or valueType == "EnumItem"
        or valueType == "Axes" or valueType == "Faces" then
        return { type = valueType, value = tostring(value) }
    elseif valueType == "table" then
        if state.seen[value] then
            return { type = "reference", id = state.seen[value] }
        end
        state.nextId = state.nextId + 1
        local id = state.nextId
        state.seen[value] = id
        if depth >= Config.PreciseMaxDepth then
            return { type = "table", id = id, truncated = "max-depth" }
        end
        local result = { type = "table", id = id, entries = {} }
        local explicitN = rawget(value, "n")
        if type(explicitN) == "number" then result.n = explicitN end
        for key, nested in pairs(value) do
            state.items = state.items + 1
            if state.items > Config.PreciseMaxItems then
                result.truncated = "max-items"
                break
            end
            table.insert(result.entries, {
                key = serializePrecise(key, depth + 1, state),
                value = serializePrecise(nested, depth + 1, state),
            })
        end
        return result
    end
    return { type = valueType, value = clampText(value) }
end

local function packedArguments(...)
    return serializePrecise(table.pack(...))
end

local function activeActionId()
    local action = Probe.ActiveAction
    if action and os.clock() - action.clock <= Config.CorrelationWindow then
        return action.id
    end
    return nil
end

local function reserveSequence()
    Probe.Sequence = Probe.Sequence + 1
    return Probe.Sequence
end

local function beginAction(kind, details)
    Probe.ActionSequence = Probe.ActionSequence + 1
    local id = string.format("A%06d", Probe.ActionSequence)
    local transaction = {
        id = id,
        kind = kind,
        clock = os.clock(),
        elapsed = os.clock() - StartedAt,
        details = serialize(details or {}),
        firstSequence = nil,
        lastSequence = nil,
        eventTypes = {},
        remotePaths = {},
        evidence = {},
    }
    Probe.ActiveAction = transaction
    Probe.Transactions[id] = transaction
    table.insert(Probe.TransactionOrder, id)
    return transaction
end

local function getAttributes(instance)
    local ok, attributes = pcall(function()
        return instance:GetAttributes()
    end)
    return ok and serialize(attributes) or {}
end

local function lowerBlob(instance, extra)
    local pieces = { instance and instance.Name or "", instance and instance.ClassName or "", extra or "" }
    if instance then
        table.insert(pieces, safePath(instance))
    end
    return string.lower(table.concat(pieces, " "))
end

local function classify(blob)
    local tags = {}
    local score = 0
    for category, words in pairs(Keywords) do
        for _, word in ipairs(words) do
            if blob:find(word, 1, true) then
                table.insert(tags, category)
                score = score + 1
                break
            end
        end
    end
    return tags, score
end

local function addCandidate(bucket, instance, extra, weight)
    local path = safePath(instance)
    local blob = lowerBlob(instance, extra)
    local tags, score = classify(blob)
    score = score + (weight or 0)
    if score <= 0 then
        return nil
    end

    local entry = bucket[path]
    if not entry then
        entry = {
            path = path,
            class = instance.ClassName,
            name = instance.Name,
            score = 0,
            hits = 0,
            tags = {},
        }
        bucket[path] = entry
    end
    entry.score = entry.score + score
    entry.hits = entry.hits + 1
    for _, tag in ipairs(tags) do
        entry.tags[tag] = true
    end
    return entry
end

local function encodeLine(event)
    local ok, encoded = pcall(HttpService.JSONEncode, HttpService, event)
    if not ok then
        Probe.EncodeErrors = Probe.EncodeErrors + 1
        return nil
    end
    return encoded
end

local function emit(eventType, data, force, options)
    if not Probe.Running and not force then
        return
    end
    if Probe.EventCount >= Config.MaxEvents and not force then
        Probe.DroppedEvents = Probe.DroppedEvents + 1
        return
    end

    Probe.EventCount = Probe.EventCount + 1
    local sequence = options and options.sequence or reserveSequence()
    Probe.EventTypes[eventType] = (Probe.EventTypes[eventType] or 0) + 1
    local actionId = options and options.actionId or activeActionId()
    local event = {
        version = 2,
        sequence = sequence,
        type = eventType,
        unix = os.time(),
        elapsed = options and options.observedElapsed or os.clock() - StartedAt,
        actionId = actionId,
        data = options and options.precise and data or serialize(data or {}),
    }
    local encoded = encodeLine(event)
    if encoded then
        table.insert(Probe.Buffer, encoded)
    end

    local transaction = actionId and Probe.Transactions[actionId] or nil
    if transaction then
        transaction.firstSequence = math.min(transaction.firstSequence or event.sequence, event.sequence)
        transaction.lastSequence = math.max(transaction.lastSequence or event.sequence, event.sequence)
        transaction.eventTypes[eventType] = (transaction.eventTypes[eventType] or 0) + 1
        if eventType == "remote_out" and options and options.remotePath then
            transaction.remotePaths[options.remotePath] = true
        elseif eventType == "state_changed" or eventType == "attribute_changed"
            or eventType == "world_added" or eventType == "world_removing" then
            transaction.evidence[eventType] = (transaction.evidence[eventType] or 0) + 1
        end
    end
end

local function flush()
    if #Probe.Buffer == 0 then
        return
    end
    local block = table.concat(Probe.Buffer, "\n") .. "\n"

    if CanAppend then
        local ok = pcall(appendfile, JsonlFile, block)
        if ok then
            table.clear(Probe.Buffer)
            return
        end
        Probe.WriteErrors = Probe.WriteErrors + 1
        if CanWrite and CanRead then
            local readOk, existing = pcall(readfile, JsonlFile)
            local recoverOk = readOk and type(existing) == "string"
                and pcall(writefile, JsonlFile, existing .. block)
            if recoverOk then
                table.clear(Probe.Buffer)
                return
            end
        end
        return -- retain the buffer and retry; never silently discard a block
    end

    if CanWrite then
        table.insert(Probe.MemoryLines, block)
        local ok = pcall(writefile, JsonlFile, table.concat(Probe.MemoryLines))
        if ok then
            table.clear(Probe.Buffer)
        else
            table.remove(Probe.MemoryLines)
            Probe.WriteErrors = Probe.WriteErrors + 1
        end
    else
        print(block)
        table.clear(Probe.Buffer)
    end
end

local function connect(signal, callback)
    local ok, connection = pcall(function()
        return signal:Connect(callback)
    end)
    if ok and connection then
        table.insert(Probe.Connections, connection)
    end
end

local function readGuiText(instance)
    if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
        return clampText(instance.Text)
    end
    local pieces = {}
    for _, descendant in ipairs(instance:GetDescendants()) do
        if (descendant:IsA("TextLabel") or descendant:IsA("TextButton")) and descendant.Text ~= "" then
            table.insert(pieces, clampText(descendant.Text))
            if #pieces >= 8 then
                break
            end
        end
    end
    return table.concat(pieces, " | ")
end

local function isActuallyVisible(instance)
    local current = instance
    while current and current ~= game do
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        if current:IsA("LayerCollector") and not current.Enabled then
            return false
        end
        current = current.Parent
    end
    return true
end

local function remoteAllowed(remote)
    local path = string.lower(safePath(remote))
    return not path:find("textchat", 1, true)
        and not path:find("defaultchat", 1, true)
        and not path:find("saymessagerequest", 1, true)
end

local RemoteWatched = setmetatable({}, { __mode = "k" })
local function snapshotRemote(remote, reason)
    local entry = addCandidate(Probe.RemoteCandidates, remote, "", 1)
    emit("remote_" .. reason, {
        remote = remote,
        candidate = entry ~= nil,
        tags = entry and entry.tags or {},
    })

    if RemoteWatched[remote] or not remoteAllowed(remote) then return end
    RemoteWatched[remote] = true
    if remote:IsA("RemoteEvent") or remote.ClassName == "UnreliableRemoteEvent" then
        connect(remote.OnClientEvent, function(...)
            if not Probe.Running then return end
            local raw = table.pack(...)
            local actionId = activeActionId()
            local remotePath = safePath(remote)
            local sequence = reserveSequence()
            local observedElapsed = os.clock() - StartedAt
            task.defer(function()
                if not Probe.Running then return end
                addCandidate(Probe.RemoteCandidates, remote, "incoming", 3)
                emit("remote_in", {
                    remote = serializePrecise(remote),
                    arguments = serializePrecise(raw),
                }, false, {
                    precise = true,
                    actionId = actionId,
                    remotePath = remotePath,
                    sequence = sequence,
                    observedElapsed = observedElapsed,
                })
            end)
        end)
    end
end

local function isRemote(instance)
    return instance:IsA("RemoteEvent")
        or instance:IsA("RemoteFunction")
        or instance.ClassName == "UnreliableRemoteEvent"
end

local function isStateValue(instance)
    return instance:IsA("ValueBase")
end

local function stateValue(instance)
    if instance:IsA("ValueBase") then
        local ok, value = pcall(function() return instance.Value end)
        return ok and value or nil
    end
    return nil
end

local StateWatched = setmetatable({}, { __mode = "k" })
local function watchStateValue(instance)
    if not instance:IsA("ValueBase") then
        return
    end
    if StateWatched[instance] then return end
    local extra = clampText(stateValue(instance))
    local entry = addCandidate(Probe.StateCandidates, instance, extra, Config.Brutal and 1 or 0)
    if not entry then
        return
    end
    StateWatched[instance] = true

    local previousValue = stateValue(instance)
    emit("state_snapshot", {
        object = instance,
        value = previousValue,
        tags = entry.tags,
    })
    connect(instance.Changed, function(value)
        if Probe.Running then
            addCandidate(Probe.StateCandidates, instance, tostring(value), 2)
            emit("state_changed", {
                object = instance,
                previous = previousValue,
                value = value,
                nearInput = os.clock() - Probe.LastInputAt <= Config.InputWindow,
                input = Probe.LastInput,
            })
            previousValue = value
        end
    end)
end

local function modelLooksRelevant(instance)
    if Config.Brutal then
        return instance:IsA("Model") or instance:IsA("Folder")
    end
    if not (instance:IsA("Model") or instance:IsA("Folder")) then
        return false
    end
    local blob = lowerBlob(instance, "")
    local _, score = classify(blob)
    if score > 0 then
        return true
    end
    local attributes = instance:GetAttributes()
    for key in pairs(attributes) do
        local tags, attributeScore = classify(string.lower(tostring(key)))
        if attributeScore > 0 or #tags > 0 then
            return true
        end
    end
    return instance:IsA("Model") and instance.PrimaryPart ~= nil and next(attributes) ~= nil
end

local AttributeWatched = setmetatable({}, { __mode = "k" })
local AttributeValues = setmetatable({}, { __mode = "k" })
local function watchAttributes(instance)
    if AttributeWatched[instance] then
        return
    end
    local attributes = instance:GetAttributes()
    if not Config.Brutal and next(attributes) == nil then
        return
    end
    AttributeWatched[instance] = true
    AttributeValues[instance] = attributes
    connect(instance.AttributeChanged, function(attributeName)
        if not Probe.Running then return end
        local ok, value = pcall(function()
            return instance:GetAttribute(attributeName)
        end)
        emit("attribute_changed", {
            object = instance,
            attribute = attributeName,
            previous = AttributeValues[instance] and AttributeValues[instance][attributeName] or nil,
            value = ok and value or nil,
            nearInput = os.clock() - Probe.LastInputAt <= Config.InputWindow,
            input = Probe.LastInput,
        })
        if AttributeValues[instance] then
            AttributeValues[instance][attributeName] = ok and value or nil
        end
    end)
end

local function logicalObject(instance)
    local existing = Probe.LogicalObjects[instance]
    if existing then return existing end
    Probe.LogicalSequence = Probe.LogicalSequence + 1
    local pivot
    if instance:IsA("Model") then
        local ok, result = pcall(function() return instance:GetPivot() end)
        if ok then pivot = serialize(result) end
    elseif instance:IsA("BasePart") then
        pivot = serialize(instance.CFrame)
    end
    local tags = {}
    pcall(function()
        for _, tag in ipairs(CollectionService:GetTags(instance)) do
            table.insert(tags, tag)
        end
    end)
    table.sort(tags)
    local identity = {
        id = string.format("O%07d", Probe.LogicalSequence),
        firstPath = safePath(instance),
        class = instance.ClassName,
        name = instance.Name,
        pivot = pivot,
        attributes = getAttributes(instance),
        tags = tags,
    }
    Probe.LogicalObjects[instance] = identity
    return identity
end

local function snapshotWorld(instance, reason)
    if Config.Brutal and reason == "added" and not (instance:IsA("Model") or instance:IsA("Folder")) then
        watchAttributes(instance)
        emit("world_instance_added", {
            object = instance,
            logical = logicalObject(instance),
            attributes = getAttributes(instance),
            nearInput = os.clock() - Probe.LastInputAt <= Config.InputWindow,
            input = Probe.LastInput,
        })
        return
    end
    if not modelLooksRelevant(instance) then
        return
    end
    watchAttributes(instance)
    local entry = addCandidate(Probe.WorldCandidates, instance, HttpService:JSONEncode(getAttributes(instance)), 1)
    emit("world_" .. reason, {
        object = instance,
        logical = logicalObject(instance),
        attributes = getAttributes(instance),
        childCount = #instance:GetChildren(),
        tags = entry and entry.tags or {},
        nearInput = os.clock() - Probe.LastInputAt <= Config.InputWindow,
        input = Probe.LastInput,
    })
end

local GuiLast = setmetatable({}, { __mode = "k" })
local function scanGui()
    for _, object in ipairs(PlayerGui:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            local text = readGuiText(object)
            local blob = lowerBlob(object, text)
            local tags, score = classify(blob)
            local visible = isActuallyVisible(object)
            if score > 0 or Config.Brutal then
                addCandidate(Probe.GuiCandidates, object, text, (visible and 1 or 0) + (Config.Brutal and 1 or 0))
                local previousState = GuiLast[object]
                local changed = not previousState
                    or previousState.text ~= text
                    or previousState.visible ~= visible
                if changed then
                    local currentState = { text = text, visible = visible }
                    GuiLast[object] = currentState
                    emit(previousState and "gui_changed" or "gui_snapshot", {
                        object = object,
                        previous = previousState,
                        text = text,
                        visible = visible,
                        tags = tags,
                        nearInput = os.clock() - Probe.LastInputAt <= Config.InputWindow,
                        input = Probe.LastInput,
                    })
                end
            end
        end
    end
end

local function inputPosition(input)
    local position = input.Position
    return { x = position.X, y = position.Y, z = position.Z }
end

local function guiAtPosition(input)
    local position = input.Position
    local ok, objects = pcall(function()
        return PlayerGui:GetGuiObjectsAtPosition(position.X, position.Y)
    end)
    local results = {}
    if ok and type(objects) == "table" then
        for index, object in ipairs(objects) do
            if index > 10 then break end
            table.insert(results, {
                object = serialize(object),
                text = readGuiText(object),
            })
        end
    end
    return results
end

local function recordInput(input, processed)
    local inputType = tostring(input.UserInputType)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch
        and input.UserInputType ~= Enum.UserInputType.Gamepad1
        and not (Config.CaptureKeyboard and input.UserInputType == Enum.UserInputType.Keyboard) then
        return
    end

    Probe.LastInputAt = os.clock()
    local details = {
        inputType = inputType,
        keyCode = tostring(input.KeyCode),
        processed = processed == true,
        position = inputPosition(input),
        gui = guiAtPosition(input),
    }
    local action = beginAction("player_input", details)
    details.actionId = action.id
    Probe.LastInput = details
    emit("player_input", Probe.LastInput)
end

local function callingContext()
    local context = {}
    if Config.CaptureCallingScript and type(getcallingscript) == "function" then
        pcall(function() context.script = getcallingscript() end)
    end
    if Config.CaptureCallingScript and debug and type(debug.info) == "function" then
        pcall(function()
            context.source = debug.info(4, "s")
            context.line = debug.info(4, "l")
            context.name = debug.info(4, "n")
        end)
    end
    return context
end

local function captureOutgoing(remote, method, rawArguments, rawReturned, context, actionId, remotePath, sequence, observedElapsed)
    if not Probe.Running or not Config.CaptureOutgoing or not remoteAllowed(remote) then return end
    task.defer(function()
        if not Probe.Running then return end
        addCandidate(Probe.RemoteCandidates, remote, method, 8)
        Probe.LastRemote = {
            method = method,
            path = remotePath,
            clock = os.clock(),
            actionId = actionId,
        }
        emit("remote_out", {
            method = method,
            remote = serializePrecise(remote),
            arguments = serializePrecise(rawArguments),
            returned = rawReturned and serializePrecise(rawReturned) or nil,
            caller = serializePrecise(context),
        }, false, {
            precise = true,
            actionId = actionId,
            remotePath = remotePath,
            sequence = sequence,
            observedElapsed = observedElapsed,
        })
    end)
end

local function installOutgoingHook()
    Environment.__UniversalTDProbeV2Capture = captureOutgoing
    Environment.__UniversalTDProbeV2Enabled = true
    if Environment.__UniversalTDProbeV2HookInstalled then
        return true, "reused"
    end
    if type(hookmetamethod) ~= "function"
        or type(getnamecallmethod) ~= "function"
        or type(newcclosure) ~= "function" then
        return false, "executor_missing_hookmetamethod"
    end

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(remote, ...)
        local method = getnamecallmethod()
        local callerIsExecutor = type(checkcaller) == "function" and checkcaller()
        local capture = Environment.__UniversalTDProbeV2Capture
        local eligible = Environment.__UniversalTDProbeV2Enabled == true
            and type(capture) == "function"
            and not callerIsExecutor
            and typeof(remote) == "Instance"
            and (method == "FireServer" or method == "InvokeServer")
        if not eligible then
            return oldNamecall(remote, ...)
        end

        -- Only cheap references/context are captured before the game call. The
        -- original transport always runs before serialization, JSON or files.
        local rawArguments = table.pack(...)
        local actionId = activeActionId()
        local sequence = reserveSequence()
        local observedElapsed = os.clock() - StartedAt
        local returned = table.pack(oldNamecall(remote, ...))
        local context = callingContext()
        local remotePath = safePath(remote)
        pcall(capture, remote, method, rawArguments, returned, context, actionId, remotePath, sequence, observedElapsed)
        return table.unpack(returned, 1, returned.n)
    end))
    Environment.__UniversalTDProbeV2HookInstalled = true
    return true, "installed"
end

local function inspectClientClosures()
    if not Config.Introspect then
        return { enabled = false, reason = "set UniversalTDProbeConfig.Introspect=true" }
    end
    if type(getgc) ~= "function" then
        return { enabled = true, available = false, reason = "getgc unavailable" }
    end
    local getConstants = debug and debug.getconstants
    local getInfo = debug and debug.getinfo
    if type(getConstants) ~= "function" then
        return { enabled = true, available = false, reason = "debug.getconstants unavailable" }
    end

    local hits = {}
    local scanned = 0
    local ok, objects = pcall(getgc, true)
    if not ok or type(objects) ~= "table" then
        return { enabled = true, available = false, reason = "getgc failed" }
    end
    for _, object in ipairs(objects) do
        if type(object) == "function" then
            scanned = scanned + 1
            local constantsOk, constants = pcall(getConstants, object)
            if constantsOk and type(constants) == "table" then
                local matched = {}
                for _, constant in pairs(constants) do
                    if type(constant) == "string" then
                        local tags, score = classify(string.lower(constant))
                        if score > 0 then
                            table.insert(matched, { value = clampText(constant), tags = tags })
                            if #matched >= 12 then break end
                        end
                    end
                end
                if #matched > 0 then
                    local info
                    if type(getInfo) == "function" then
                        pcall(function() info = getInfo(object) end)
                    end
                    table.insert(hits, { info = serialize(info), constants = matched })
                    if #hits >= 250 then break end
                end
            end
        end
    end
    emit("client_introspection", { scannedFunctions = scanned, hits = hits })
    return { enabled = true, available = true, scannedFunctions = scanned, hits = #hits }
end

local function candidateList(bucket)
    local list = {}
    for _, entry in pairs(bucket) do
        local tags = {}
        for tag in pairs(entry.tags) do
            table.insert(tags, tag)
        end
        table.sort(tags)
        table.insert(list, {
            path = entry.path,
            class = entry.class,
            name = entry.name,
            score = entry.score,
            hits = entry.hits,
            tags = tags,
        })
    end
    table.sort(list, function(a, b)
        if a.score == b.score then
            return a.path < b.path
        end
        return a.score > b.score
    end)
    return list
end

local function transactionList()
    local list = {}
    for _, id in ipairs(Probe.TransactionOrder) do
        local transaction = Probe.Transactions[id]
        local remotes = {}
        for path in pairs(transaction.remotePaths) do table.insert(remotes, path) end
        table.sort(remotes)
        local remoteOut = transaction.eventTypes.remote_out or 0
        local evidenceCount = 0
        for _, count in pairs(transaction.evidence) do evidenceCount = evidenceCount + count end
        table.insert(list, {
            id = transaction.id,
            kind = transaction.kind,
            elapsed = transaction.elapsed,
            details = transaction.details,
            firstSequence = transaction.firstSequence,
            lastSequence = transaction.lastSequence,
            eventTypes = serialize(transaction.eventTypes),
            remotes = remotes,
            evidence = serialize(transaction.evidence),
            classification = remoteOut == 0 and "no_remote_observed"
                or evidenceCount == 0 and "remote_without_state_evidence"
                or "remote_with_correlated_evidence",
        })
    end
    return list
end

local function buildSummary(reason)
    return {
        version = 2,
        reason = reason or "snapshot",
        placeId = game.PlaceId,
        jobId = game.JobId,
        duration = os.clock() - StartedAt,
        eventCount = Probe.EventCount,
        droppedEvents = Probe.DroppedEvents,
        encodeErrors = Probe.EncodeErrors,
        writeErrors = Probe.WriteErrors,
        eventTypes = serialize(Probe.EventTypes),
        files = { jsonl = JsonlFile, summary = SummaryFile },
        candidates = {
            remotes = candidateList(Probe.RemoteCandidates),
            state = candidateList(Probe.StateCandidates),
            world = candidateList(Probe.WorldCandidates),
            gui = candidateList(Probe.GuiCandidates),
        },
        transactions = transactionList(),
        limitations = {
            "Correlation is evidence, not a guaranteed server acknowledgement.",
            "Server-only state and non-replicated objects are invisible to any client probe.",
            "A stopped metamethod hook remains installed but inert and is reused on the next V2 run.",
        },
    }
end

function Probe.Mark(label, details)
    Probe.LastInputAt = os.clock()
    local payload = {
        manual = true,
        label = tostring(label or "MARK"),
        details = serialize(details),
    }
    local action = beginAction("manual_mark", payload)
    payload.actionId = action.id
    Probe.LastInput = payload
    emit("manual_mark", Probe.LastInput)
    print("[Universal TD Probe] Marked:", Probe.LastInput.label)
end

function Probe.Snapshot()
    scanGui()
    local summary = buildSummary("manual_snapshot")
    emit("summary_snapshot", summary)
    flush()
    if CanWrite then
        pcall(writefile, SummaryFile, HttpService:JSONEncode(summary))
    end
    return summary
end

function Probe.Status()
    return {
        running = Probe.Running,
        mode = Config.Mode,
        hook = serialize(Probe.Hook),
        events = Probe.EventCount,
        dropped = Probe.DroppedEvents,
        encodeErrors = Probe.EncodeErrors,
        writeErrors = Probe.WriteErrors,
        activeAction = activeActionId(),
        jsonl = JsonlFile,
        summary = SummaryFile,
    }
end

function Probe.InspectClient()
    return inspectClientClosures()
end

function Probe.Stop(reason)
    if not Probe.Running then
        return Probe.Status()
    end
    Probe.Running = false
    if Environment.UniversalTDProbe == Probe then
        Environment.__UniversalTDProbeV2Enabled = false
    end
    for _, connection in ipairs(Probe.Connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(Probe.Connections)

    local summary = buildSummary(reason or "manual")
    emit("session_stopped", summary, true)
    flush()
    if CanWrite then
        pcall(writefile, SummaryFile, HttpService:JSONEncode(summary))
    end
    print("[Universal TD Probe] Stopped. Files:", JsonlFile, SummaryFile)
    return summary
end

if CanWrite then
    local ok = pcall(writefile, JsonlFile, "")
    if not ok then Probe.WriteErrors = Probe.WriteErrors + 1 end
end

local hookOk, hookState = false, "disabled_for_mode"
if Config.CaptureOutgoing then
    hookOk, hookState = installOutgoingHook()
end
Probe.Hook = { enabled = Config.CaptureOutgoing, available = hookOk, state = hookState }

emit("session_started", {
    placeId = game.PlaceId,
    jobId = game.JobId,
    config = Config,
    hook = Probe.Hook,
    note = Config.CaptureOutgoing
        and "Original remote call runs before deferred serialization/logging."
        or "Passive mode; outgoing remote calls are not hooked.",
})

local remoteRoot = Config.Perfect and game or ReplicatedStorage
for _, descendant in ipairs(remoteRoot:GetDescendants()) do
    if isRemote(descendant) then
        snapshotRemote(descendant, "inventory")
    elseif descendant:IsDescendantOf(ReplicatedStorage) and isStateValue(descendant) then
        watchStateValue(descendant)
    end
end

for _, descendant in ipairs(LocalPlayer:GetDescendants()) do
    if isStateValue(descendant) then
        watchStateValue(descendant)
    end
end

for _, descendant in ipairs(Workspace:GetDescendants()) do
    if Config.Brutal and isStateValue(descendant) then
        watchStateValue(descendant)
    end
    snapshotWorld(descendant, "inventory")
end

connect(remoteRoot.DescendantAdded, function(instance)
    task.defer(function()
        if not Probe.Running or not instance.Parent then return end
        if isRemote(instance) then
            snapshotRemote(instance, "added")
        elseif isStateValue(instance) then
            watchStateValue(instance)
        end
    end)
end)

connect(LocalPlayer.DescendantAdded, function(instance)
    task.defer(function()
        if Probe.Running and instance.Parent and isStateValue(instance) then
            watchStateValue(instance)
        end
    end)
end)

connect(Workspace.DescendantAdded, function(instance)
    task.defer(function()
        if Probe.Running and instance.Parent then
            if Config.Brutal and isStateValue(instance) then
                watchStateValue(instance)
            end
            snapshotWorld(instance, "added")
        end
    end)
end)

connect(Workspace.DescendantRemoving, function(instance)
    if Probe.Running and (Probe.WorldCandidates[safePath(instance)] or modelLooksRelevant(instance)) then
        emit("world_removing", {
            object = instance,
            logical = logicalObject(instance),
            attributes = getAttributes(instance),
            nearInput = os.clock() - Probe.LastInputAt <= Config.InputWindow,
            input = Probe.LastInput,
        })
    end
end)

-- InputBegan precedes most Activated/MouseButton callbacks, so the action id is
-- already available when the game's LocalScript sends its remote.
connect(UserInputService.InputBegan, recordInput)
connect(LogService.MessageOut, function(message, messageType)
    local lowered = string.lower(tostring(message))
    if lowered:find("error", 1, true)
        or lowered:find("failed", 1, true)
        or lowered:find("attempt to", 1, true) then
        emit("client_log", {
            message = clampText(message),
            messageType = tostring(messageType),
        })
    end
end)

task.spawn(function()
    while Probe.Running do
        scanGui()
        task.wait(Config.ScanInterval)
    end
end)

if Config.Introspect then
    task.defer(function()
        if Probe.Running then inspectClientClosures() end
    end)
end

task.spawn(function()
    while Probe.Running do
        task.wait(Config.FlushInterval)
        flush()
    end
end)

task.delay(Config.Duration, function()
    if Probe.Running then
        Probe.Stop("duration_limit")
    end
end)

flush()
print("[Universal TD Probe] Running in", Config.Mode, "mode.")
print("[Universal TD Probe] Play normally, then run: getgenv().UniversalTDProbe.Stop()")
print("[Universal TD Probe] Files:", JsonlFile, SummaryFile)
