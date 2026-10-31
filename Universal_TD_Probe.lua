-- Universal TD Probe v2.7 (standard namecall opt-in; independent direct/OTH observation)
-- Passive discovery in Normal/Brutal modes and loss-minimising transport/state
-- correlation in Perfect mode. The probe never calls a game remote itself.
-- Direct execution defaults to Brutal_Perfect; explicit Mode still overrides it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local LogService = game:GetService("LogService")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Environment = getgenv()
local previous = Environment.UniversalTDProbe
if previous and type(previous.Stop) == "function" then
    pcall(previous.Stop, "replaced")
end
-- v2.1 reflection before forwarding __namecall can corrupt the executor's
-- current method. Make its resident wrappers forward immediately, untouched.
Environment.__UniversalTDProbeV21Observe = nil
Environment.__UniversalTDProbeV2Enabled = false

local userConfig = type(Environment.UniversalTDProbeConfig) == "table"
    and Environment.UniversalTDProbeConfig
    or {}

local requestedMode = string.lower(tostring(userConfig.Mode or "Brutal_Perfect"))
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
    BufferMaxBytes = math.max(1, math.floor(tonumber(userConfig.BufferMaxBytes) or 262144)),
    CaptureOutgoing = userConfig.CaptureOutgoing ~= false and isPerfect,
    CaptureNamecall = userConfig.CaptureNamecall ~= false and isPerfect,
    -- Brutal_Perfect is also used to diagnose hub playback. Include calls
    -- made by the executor so failed/missing automation is visible in JSONL.
    CaptureExecutorCalls = userConfig.CaptureExecutorCalls ~= false and isPerfect,
    CaptureCallingScript = userConfig.CaptureCallingScript ~= false,
    CaptureKeyboard = userConfig.CaptureKeyboard ~= false and isPerfect,
    CaptureInteractions = userConfig.CaptureInteractions ~= false and isPerfect,
    CaptureWorldGui = userConfig.CaptureWorldGui ~= false,
    CaptureLocalCalls = false, -- retired: no Bindable/native helper interception
    CaptureExecutorHelpers = false,
    CaptureWorldInstances = userConfig.CaptureWorldInstances == true,
    CaptureModuleInventory = userConfig.CaptureModuleInventory ~= false and isPerfect,
    CaptureInternalModules = userConfig.CaptureInternalModules == true,
    HookBackend = userConfig.HookBackend == "Standard" and "Standard" or userConfig.HookBackend == "OTH" and "OTH" or "Auto",
    -- Standard namecall interception triggered the observed Skibi detector.
    -- Keep it explicit opt-in; direct hooks do not guarantee full coverage.
    AllowStandardNamecall = userConfig.AllowStandardNamecall == true,
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
    Diagnostics = { attempts = 0, completed = 0, failed = 0, incoming = 0,
        captureErrors = 0, byPath = {}, revision = "2.7" },
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
    merge = { "merge", "fusion", "fuse", "roll", "reveal" },
    rarity = { "rarity", "common", "rare", "epic", "legendary", "mythic", "secret" },
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

-- Snapshot binary payloads synchronously; hex/JSON encoding remains deferred.
-- Bound work and disclose truncation instead of silently losing payload bytes.
local FrozenBuffers = setmetatable({}, { __mode = "k" })
local function freezeBuffer(value)
    local frozen = {}
    local info = { type = "buffer", encoding = "hex", snapshot = true }
    FrozenBuffers[frozen] = info
    if not buffer or type(buffer.len) ~= "function" or type(buffer.readstring) ~= "function" then
        info.error = "buffer API unavailable"
        return frozen
    end
    local ok, length = pcall(buffer.len, value)
    if not ok then info.error = "buffer length unavailable"; return frozen end
    info.byteLength = length
    info.capturedBytes = math.min(length, Config.BufferMaxBytes)
    info.truncated = info.capturedBytes < length
    local readOK, bytes = pcall(buffer.readstring, value, 0, info.capturedBytes)
    if readOK then info.bytes = bytes else info.error = "buffer read failed" end
    return frozen
end
local function encodeFrozenBuffer(info)
    local result = { type = "buffer", encoding = "hex", snapshot = true,
        byteLength = info.byteLength, capturedBytes = info.capturedBytes,
        truncated = info.truncated, error = info.error }
    if info.bytes then
        result.data = (info.bytes:gsub(".", function(char) return string.format("%02x", string.byte(char)) end))
    end
    return result
end
local function snapshotArguments(value, depth, state)
    if FrozenBuffers[value] then return value end
    local kind = typeof(value)
    if kind == "buffer" then return freezeBuffer(value) end
    if kind ~= "table" then return value end
    depth = depth or 0
    state = state or { seen = {}, items = 0 }
    if state.seen[value] then return state.seen[value] end
    -- The precise serializer does not visit data beyond these same limits.
    if depth >= Config.PreciseMaxDepth then return value end
    local copy = {}
    state.seen[value] = copy
    for key, nested in pairs(value) do
        state.items = state.items + 1
        if state.items > Config.PreciseMaxItems then
            -- Retain the remainder for the serializer's existing truncation marker.
            copy[key] = nested
            break
        end
        copy[snapshotArguments(key, depth + 1, state)] = snapshotArguments(nested, depth + 1, state)
    end
    return copy
end
Environment.__UniversalTDProbeV2Snapshot = snapshotArguments
local function safeArgumentSnapshot(value)
    local snapshot = Environment.__UniversalTDProbeV2Snapshot
    if type(snapshot) ~= "function" then return value end
    local ok, result = pcall(snapshot, value)
    return ok and result or value
end

local function serialize(value, depth)
    if FrozenBuffers[value] then return encodeFrozenBuffer(FrozenBuffers[value]) end
    if typeof(value) == "buffer" then return encodeFrozenBuffer(FrozenBuffers[freezeBuffer(value)]) end
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
    if FrozenBuffers[value] then return encodeFrozenBuffer(FrozenBuffers[value]) end
    if typeof(value) == "buffer" then return encodeFrozenBuffer(FrozenBuffers[freezeBuffer(value)]) end
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
        if (eventType == "remote_out" or eventType == "remote_attempt" or eventType == "remote_error")
            and options and options.remotePath then
            transaction.remotePaths[options.remotePath] = true
        elseif eventType == "state_changed" or eventType == "attribute_changed"
            or eventType == "world_added" or eventType == "world_removing"
            or eventType == "prompt_changed" or eventType == "gui_changed" then
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
            Probe.Diagnostics.incoming = Probe.Diagnostics.incoming + 1
            local raw = safeArgumentSnapshot(table.pack(...))
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

local WorldText = setmetatable({}, { __mode = "k" })
local PromptWatched = setmetatable({}, { __mode = "k" })
local ButtonWatched = setmetatable({}, { __mode = "k" })
local ModuleWatched = setmetatable({}, { __mode = "k" })
local function playerPosition()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return root and root.Position or nil
end
local function promptDetails(prompt)
    local parent, point = prompt.Parent, nil
    if parent then
        if parent:IsA("Attachment") then point = parent.WorldPosition
        elseif parent:IsA("BasePart") then point = parent.Position
        elseif parent:IsA("Model") then point = parent:GetPivot().Position end
    end
    local position = playerPosition()
    local distance = point and position and (point - position).Magnitude or nil
    return { object = prompt, objectId = logicalObject(prompt).id,
        enabled = prompt.Enabled, actionText = prompt.ActionText, objectText = prompt.ObjectText,
        holdDuration = prompt.HoldDuration, maxDistance = prompt.MaxActivationDistance,
        requiresLineOfSight = prompt.RequiresLineOfSight,
        keyboardKeyCode = tostring(prompt.KeyboardKeyCode), position = point,
        playerPosition = position, distance = distance,
        withinDistance = distance ~= nil and distance <= prompt.MaxActivationDistance }
end
local function watchInteraction(instance)
    if Config.CaptureWorldGui and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
        and instance:IsDescendantOf(Workspace) then WorldText[instance] = true end
    if Config.CaptureInteractions and instance:IsA("ProximityPrompt") and not PromptWatched[instance] then
        PromptWatched[instance] = true
        emit("prompt_snapshot", promptDetails(instance))
        for _, property in ipairs({ "Enabled", "ActionText", "ObjectText", "HoldDuration",
            "MaxActivationDistance", "RequiresLineOfSight", "KeyboardKeyCode" }) do
            connect(instance:GetPropertyChangedSignal(property), function()
                if not Probe.Running then return end
                local details = promptDetails(instance)
                details.property = property
                emit("prompt_changed", details)
            end)
        end
    end
end
local function watchButton(instance)
    if not Config.CaptureInteractions or not instance:IsA("GuiButton") or ButtonWatched[instance] then return end
    ButtonWatched[instance] = true
    connect(instance.Activated, function(input, clickCount)
        if not Probe.Running then return end
        emit("gui_activated", { object = instance, objectId = logicalObject(instance).id,
            text = readGuiText(instance), visible = isActuallyVisible(instance),
            inputType = input and tostring(input.UserInputType), clickCount = clickCount })
    end)
end
local function inventoryModule(instance)
    if not Config.CaptureModuleInventory or not instance:IsA("ModuleScript") or ModuleWatched[instance] then return end
    ModuleWatched[instance] = true
    if not Config.CaptureInternalModules then
        local path = safePath(instance)
        if path:match("^CorePackages%.") or path:match("^CoreGui%.RobloxGui%.") then return end
    end
    emit("module_inventory", { object = instance, objectId = logicalObject(instance).id,
        attributes = getAttributes(instance), note = "Inventory only; module was not required or executed." })
end
local function snapshotWorld(instance, reason)
    watchInteraction(instance)
    inventoryModule(instance)
    if Config.Brutal and reason == "added" and not (instance:IsA("Model") or instance:IsA("Folder")) then
        if not Config.CaptureWorldInstances then return end
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
    local function scanObject(object)
        watchButton(object)
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
                        objectId = logicalObject(object).id,
                        scope = object:IsDescendantOf(Workspace) and "workspace" or "playergui",
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
    for _, object in ipairs(PlayerGui:GetDescendants()) do scanObject(object) end
    for object in pairs(WorldText) do
        if object.Parent then scanObject(object) else WorldText[object] = nil end
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

-- Installed hooks dispatch through the current run; no stale Config/callbacks.
-- Legacy v2 hooks may remain resident, but their capture switch stays disabled.
Environment.__UniversalTDProbeV2Enabled = false
local HookBypass = Environment.__UniversalTDProbeV22Bypass or setmetatable({}, { __mode = "k" })
Environment.__UniversalTDProbeV22Bypass = HookBypass
local MainThreadKey = Environment.__UniversalTDProbeV22MainThread or {}
Environment.__UniversalTDProbeV22MainThread = MainThreadKey
local function observationThread()
    if type(oth)=="table" and type(oth.is_hook_thread)=="function"
        and type(oth.get_original_thread)=="function" then
        local ok,isHook=pcall(oth.is_hook_thread)
        if ok and isHook then
            local found,thread=pcall(oth.get_original_thread)
            if found and thread~=nil then return thread end
        end
    end
    return coroutine.running() or MainThreadKey
end
local function observedKind(object, method)
    if typeof(object) == "Instance" and (method == "FireServer" or method == "InvokeServer")
        and isRemote(object) and remoteAllowed(object) then return "remote" end
end
local function prepareCall(object, method, capturePath, executor, ...)
    if not Probe.Running or (executor and not Config.CaptureExecutorCalls) then return end
    local kind = observedKind(object, method)
    if not kind or (kind == "remote" and not Config.CaptureOutgoing) then return end
    local ticket = { object = object, method = method, kind = kind,
        capturePath = capturePath, executor = executor == true,
        arguments = safeArgumentSnapshot(table.pack(...)), caller = callingContext(),
        actionId = activeActionId(), path = safePath(object), clock = os.clock(),
        sequence = reserveSequence() }
    Probe.Diagnostics.attempts = Probe.Diagnostics.attempts + 1
    Probe.Diagnostics.byPath[capturePath] = (Probe.Diagnostics.byPath[capturePath] or 0) + 1
    Probe.Diagnostics.lastAttemptAt = ticket.clock - StartedAt
    task.defer(function()
        if not Probe.Running then return end
        local ok, err = pcall(function()
            emit(kind .. "_attempt", { object = serializePrecise(object), method = method,
                capturePath = capturePath, executor = ticket.executor,
                argumentCapture = ticket.argumentCapture or "before_forward",
                arguments = serializePrecise(ticket.arguments), caller = serializePrecise(ticket.caller) }, false,
                { precise = true, actionId = ticket.actionId, sequence = ticket.sequence,
                    observedElapsed = ticket.clock - StartedAt, remotePath = ticket.path })
        end)
        if not ok then
            Probe.Diagnostics.captureErrors = Probe.Diagnostics.captureErrors + 1
            Probe.Diagnostics.lastCaptureError = clampText(err)
        end
    end)
    return ticket
end
local function completeCall(ticket, result)
    local succeeded = result[1]
    local returned = succeeded and safeArgumentSnapshot(table.pack(table.unpack(result, 2, result.n))) or nil
    local finished, sequence = os.clock(), reserveSequence()
    if succeeded then Probe.Diagnostics.completed = Probe.Diagnostics.completed + 1
    else Probe.Diagnostics.failed = Probe.Diagnostics.failed + 1 end
    task.defer(function()
        if not Probe.Running then return end
        local ok, err = pcall(function()
            if ticket.kind == "remote" then
                addCandidate(Probe.RemoteCandidates, ticket.object, ticket.method, 8)
                Probe.LastRemote = { method = ticket.method, path = ticket.path,
                    clock = finished, actionId = ticket.actionId }
            end
            local eventType = succeeded and (ticket.kind == "remote" and "remote_out" or ticket.kind .. "_call")
                or ticket.kind .. "_error"
            emit(eventType, { method = ticket.method, capturePath = ticket.capturePath,
                remote = serializePrecise(ticket.object), object = serializePrecise(ticket.object),
                arguments = serializePrecise(ticket.arguments), returned = returned and serializePrecise(returned),
                caller = serializePrecise(ticket.caller), executor = ticket.executor,
                attemptSequence = ticket.sequence, duration = finished - ticket.clock,
                argumentCapture = ticket.argumentCapture or "before_forward",
                success = succeeded, error = not succeeded and clampText(result[2]) or nil }, false,
                { precise = true, actionId = ticket.actionId, remotePath = ticket.path,
                    sequence = sequence, observedElapsed = finished - StartedAt })
        end)
        if not ok then
            Probe.Diagnostics.captureErrors = Probe.Diagnostics.captureErrors + 1
            Probe.Diagnostics.lastCaptureError = clampText(err)
        end
    end)
end
Environment.__UniversalTDProbeV22Observe = function(original, object, method, capturePath, executor, ...)
    local thread = observationThread()
    local bypass = HookBypass[thread]
    if not Probe.Running or (bypass and bypass.object == object and bypass.method == method) then
        return original(object, ...)
    end
    local prepared, ticket = pcall(prepareCall, object, method, capturePath, executor, ...)
    if not prepared then
        Probe.Diagnostics.captureErrors = Probe.Diagnostics.captureErrors + 1
        Probe.Diagnostics.lastCaptureError = clampText(ticket)
    end
    if not prepared or not ticket then return original(object, ...) end
    HookBypass[thread] = { object = object, method = method }
    local result = table.pack(pcall(original, object, ...))
    HookBypass[thread] = bypass
    local ok, err = pcall(completeCall, ticket, result)
    if not ok then
        Probe.Diagnostics.captureErrors = Probe.Diagnostics.captureErrors + 1
        Probe.Diagnostics.lastCaptureError = clampText(err)
    end
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end
-- Adapt the backend selection used by Cobalt, without importing/running Cobalt.
-- OTH receives a plain callback; standard hooks require newcclosure.
local function chooseHookBackend(target)
    if Config.HookBackend ~= "Standard" and type(oth)=="table" and type(oth.hook)=="function"
        and type(iscclosure)=="function" and type(target)=="function" then
        local ok,native=pcall(iscclosure,target)
        if ok and native then return "oth",oth.hook end
    end
    if Config.HookBackend=="OTH" then return nil,nil,"oth_unavailable" end
    if type(hookfunction)=="function" and type(newcclosure)=="function" then return "standard",hookfunction end
    return nil,nil,"executor_missing_hookfunction"
end
local function installFunctionHook(target, method, key)
    local registry = Environment.__UniversalTDProbeV22DirectInstalled or {}
    Environment.__UniversalTDProbeV22DirectInstalled = registry
    if type(target) ~= "function" then return false, "function_unavailable" end
    local backend,hook,problem=chooseHookBackend(target)
    if not backend then return false,problem end
    if registry[key] then
        local previous=type(registry[key])=="table" and registry[key].backend or "standard"
        if previous~=backend then return false,"backend_change_requires_fresh_session" end
        return true,"reused_"..backend
    end
    local original
    local ok, err = pcall(function()
        local callback=function(object, ...)
            local observer = Environment.__UniversalTDProbeV22Observe
            if type(observer) == "function" then
                local executor = type(checkcaller) == "function" and checkcaller()
                return observer(original, object, method, key, executor, ...)
            end
            return original(object, ...)
        end
        original=hook(target,backend=="oth" and callback or newcclosure(callback))
    end)
    if not ok or type(original) ~= "function" then return false, "hook_failed:" .. clampText(err) end
    registry[key] = {backend=backend}
    return true, "installed_"..backend
end
local function installDirectMethodHook(className, method)
    local created, sample = pcall(Instance.new, className)
    if not created then return false, "class_unavailable" end
    local ok, target = pcall(function() return sample[method] end)
    sample:Destroy()
    if not ok then return false, "method_unavailable" end
    return installFunctionHook(target, method, className .. "." .. method)
end
-- Unlike direct function hooks, __namecall must not inspect Instances, callers,
-- or buffers before forwarding: executor reflection can replace its current
-- engine method. Capture only after the original call returns. Arguments may
-- already have been mutated; expose that limitation explicitly in every event.
Environment.__UniversalTDProbeV23NamecallObserve = Config.CaptureOutgoing and Config.CaptureNamecall and function(object, method, arguments, result, entered, executor)
    local ticket = prepareCall(object, method, "__namecall", executor, table.unpack(arguments, 1, arguments.n))
    if not ticket then return end
    ticket.clock, ticket.argumentCapture = entered, "after_forward"
    completeCall(ticket, result)
end or nil
local function installForwardFirstNamecall()
    if not Config.CaptureNamecall then return false, "disabled_by_config" end
    if type(getnamecallmethod)~="function" then return false,"executor_missing_namecall_api" end
    local getMeta=getrawmetatable or (debug and debug.getmetatable)
    local target
    if type(getMeta)=="function" then
        local ok,meta=pcall(getMeta,game)
        if ok and type(meta)=="table" then target=rawget(meta,"__namecall") end
    end
    local backend,hook=chooseHookBackend(target)
    backend=backend=="oth" and "oth" or "standard"
    if backend=="standard" then
        if Config.HookBackend=="OTH" then return false,"oth_unavailable" end
        if not Config.AllowStandardNamecall then return false,"standard_namecall_requires_opt_in" end
        if type(hookmetamethod)~="function" or type(newcclosure)~="function" then
            return false,"executor_missing_namecall_api"
        end
    end
    if Environment.__UniversalTDProbeV23NamecallInstalled then
        local previous=Environment.__UniversalTDProbeV25NamecallBackend or "standard"
        if previous~=backend then return false,"backend_change_requires_fresh_session" end
        return true,"reused_forward_first_"..backend
    end
    local original
    local ok, err = pcall(function()
        local callback=function(object, ...)
            local method = getnamecallmethod()
            local observer = Environment.__UniversalTDProbeV23NamecallObserve
            if type(observer) ~= "function" or (method ~= "FireServer" and method ~= "InvokeServer") then
                return original(object, ...)
            end
            local thread = observationThread()
            local bypass = HookBypass[thread]
            if bypass and bypass.object == object and bypass.method == method then
                return original(object, ...)
            end
            -- No Instance access, serialization or calling-context inspection
            -- is allowed above the pcall(original, ...) boundary below.
            local arguments, entered = table.pack(...), os.clock()
            HookBypass[thread] = { object = object, method = method }
            local result = table.pack(pcall(original, object, ...))
            local executor = false
            if type(checkcaller) == "function" then
                local checked, value = pcall(checkcaller)
                executor = checked and value == true
            end
            local captured, captureError = pcall(observer, object, method, arguments, result, entered, executor)
            HookBypass[thread] = bypass
            if not captured then
                -- Capture failure must not replace the original return/error.
                local diagnostics = Environment.UniversalTDProbe and Environment.UniversalTDProbe.Diagnostics
                if diagnostics then
                    diagnostics.captureErrors = diagnostics.captureErrors + 1
                    diagnostics.lastCaptureError = tostring(captureError)
                end
            end
            if not result[1] then error(result[2], 0) end
            return table.unpack(result, 2, result.n)
        end
        if backend=="oth" then original=hook(target,callback)
        else original=hookmetamethod(game,"__namecall",newcclosure(callback)) end
    end)
    if not ok or type(original) ~= "function" then return false, "namecall_hook_failed:" .. clampText(err) end
    Environment.__UniversalTDProbeV23NamecallInstalled = true
    Environment.__UniversalTDProbeV25NamecallBackend = backend
    return true, "installed_forward_first_"..backend
end
local function installOutgoingHooks()
    local paths = {}
    local function note(key, ok, state) paths[key] = { available = ok, state = state } end
    note("namecall", installForwardFirstNamecall())
    if not paths.namecall.available then Environment.__UniversalTDProbeV23NamecallObserve=nil end
    note("fireServer", installDirectMethodHook("RemoteEvent", "FireServer"))
    note("invokeServer", installDirectMethodHook("RemoteFunction", "InvokeServer"))
    note("unreliableFireServer", installDirectMethodHook("UnreliableRemoteEvent", "FireServer"))
    local any, core = false, paths.fireServer.available and paths.invokeServer.available
    for _, path in pairs(paths) do any = any or path.available end
    return any, core and paths.namecall.available and "namecall_and_direct_hooks_installed"
        or core and "direct_remote_hooks_installed" or any and "installed_partial" or "unavailable", paths
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
        local remoteAttempts = transaction.eventTypes.remote_attempt or 0
        local remoteErrors = transaction.eventTypes.remote_error or 0
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
            classification = remoteAttempts > remoteOut + remoteErrors and "remote_pending_or_unfinished"
                or remoteErrors > 0 and remoteOut == 0 and "remote_failed_locally"
                or remoteOut == 0 and "no_remote_observed"
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
        coreRevision = "2.7",
        hook = Probe.Hook,
        diagnostics = Probe.Diagnostics,
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
            "Stopped outgoing hooks remain installed but inert and are reused on the next run.",
            "Direct remote hooks are not proof of coverage; compare attempt/completion counters after manual actions.",
            "Actor/parallel/native executor paths may bypass these hooks; this probe does not inject into other VMs.",
            "A successful local call or withinDistance=true does not prove server acceptance or line of sight.",
        },
    }
end

function Probe.Mark(label, details)
    Probe.LastInputAt = os.clock()
    local payload = {
        manual = true,
        label = tostring(label or "MARK"),
        playerPosition = playerPosition(),
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
        diagnostics = serialize(Probe.Diagnostics),
        coreRevision = "2.7",
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
    if not Probe.Running or Probe.Stopping then
        return Probe.Status()
    end
    Probe.Stopping = true
    Probe.Running = false
    if Environment.UniversalTDProbe == Probe then
        Environment.__UniversalTDProbeV2Enabled = false
        Environment.__UniversalTDProbeV23NamecallObserve = nil
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
local hookDetails = {}
if Config.CaptureOutgoing then
    hookOk, hookState, hookDetails = installOutgoingHooks()
end
Probe.Hook = {
    enabled = Config.CaptureOutgoing,
    available = hookOk,
    state = hookState,
    paths = hookDetails,
    capabilities = {
        othHook = type(oth) == "table" and type(oth.hook) == "function",
        nativeClosureCheck = type(iscclosure) == "function",
        hookmetamethod = type(hookmetamethod) == "function",
        rawMetatable = type(getrawmetatable) == "function" or (debug ~= nil and type(debug.getmetatable) == "function"),
        standardNamecallAllowed = Config.AllowStandardNamecall,
    },
}

local executorInfo = { name = "unavailable" }
local identify = identifyexecutor or getexecutorname
if type(identify) == "function" then
    local ok, name, version = pcall(identify)
    if ok then executorInfo.name, executorInfo.version = tostring(name), version and tostring(version) end
end
emit("session_started", {
    coreRevision = "2.7",
    executor = executorInfo,
    placeId = game.PlaceId,
    jobId = game.JobId,
    config = Config,
    hook = Probe.Hook,
    note = Config.CaptureOutgoing
        and "Direct hooks freeze arguments before forwarding; namecall captures after forwarding to preserve native method context. See argumentCapture. Serialization is deferred; success is not server acknowledgement."
        or "Passive mode; outgoing remote calls are not hooked.",
})



local remoteRoot = Config.Perfect and game or ReplicatedStorage
for _, descendant in ipairs(remoteRoot:GetDescendants()) do
    inventoryModule(descendant)
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
        inventoryModule(instance)
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
if Config.CaptureInteractions then
    for _, eventName in ipairs({ "PromptShown", "PromptHidden", "PromptButtonHoldBegan",
        "PromptButtonHoldEnded", "PromptTriggered", "PromptTriggerEnded" }) do
        local ok, signal = pcall(function() return ProximityPromptService[eventName] end)
        if ok and signal then
            connect(signal, function(prompt, actorOrInput)
                if not Probe.Running or typeof(prompt) ~= "Instance" then return end
                watchInteraction(prompt)
                local details = promptDetails(prompt)
                details.event = eventName
                details.actorOrInput = actorOrInput
                if eventName == "PromptButtonHoldBegan" then
                    Probe.LastInputAt = os.clock()
                    local action = beginAction("prompt_input", details)
                    details.actionId = action.id
                    Probe.LastInput = details
                end
                emit("prompt_event", details)
            end)
        else
            emit("capability_unavailable", { capability = eventName, reason = "Prompt service signal unavailable" })
        end
    end
end
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

task.spawn(function()
    local warned = false
    while Probe.Running do
        task.wait(10)
        if not Probe.Running then break end
        emit("capture_health", { diagnostics = Probe.Diagnostics,
            remoteAttempts = Probe.EventTypes.remote_attempt or 0,
            remoteCompleted = Probe.EventTypes.remote_out or 0,
            remoteErrors = Probe.EventTypes.remote_error or 0,
            hookInstalled = Probe.Hook.available,
            note = "Counters measure observed calls, not guaranteed transport coverage." })
        if not warned and Config.CaptureOutgoing and Probe.ActionSequence > 0
            and (Probe.EventTypes.remote_attempt or 0) == 0 then
            warned = true
            emit("capture_warning", { reason = "actions_without_outgoing_observation",
                incoming = Probe.Diagnostics.incoming,
                hints = { "Action may not send a remote", "Check executor hook support",
                    "Try a clean rejoin with this core", "Parallel/native paths can bypass client hooks" } })
        end
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
print("[Universal TD Probe 2.7] Running in", Config.Mode, "mode.")
if Config.CaptureOutgoing then
    local paths = Probe.Hook.paths or {}
    print(
        "[Universal TD Probe] Hooks:",
        "__namecall=" .. tostring(paths.namecall and paths.namecall.state or "unavailable"),
        "InvokeServer=" .. tostring(paths.invokeServer and paths.invokeServer.state or "unavailable"),
        "FireServer=" .. tostring(paths.fireServer and paths.fireServer.state or "unavailable")
    )
end
print("[Universal TD Probe] Play normally, then run: getgenv().UniversalTDProbe.Stop()")
print("[Universal TD Probe] Files:", JsonlFile, SummaryFile)
