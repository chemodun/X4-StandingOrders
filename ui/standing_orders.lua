local ffi = require("ffi")
local C = ffi.C
local utf8 = require("utf8")

ffi.cdef [[
  typedef uint64_t UniverseID;

  typedef struct {
   size_t queueidx;
   const char* state;
   const char* statename;
   const char* orderdef;
   size_t actualparams;
   bool enabled;
   bool isinfinite;
   bool issyncpointreached;
   bool istemporder;
  } Order;

  typedef struct {
   const char* name;
   const char* transport;
   uint32_t spaceused;
   uint32_t capacity;
  } StorageInfo;

	typedef struct {
		const char* id;
		const char* name;
		const char* icon;
		const char* description;
		const char* category;
		const char* categoryname;
		bool infinite;
		uint32_t requiredSkill;
	} OrderDefinition;

	typedef struct {
		const char* ware;
		int32_t current;
		int32_t max;
	} WareYield;

	typedef struct {
		const char* shape;
		const char* name;
		uint32_t requiredSkill;
		float radius;
		bool rollMembers;
		bool rollFormation;
		size_t maxShipsPerLine;
	} UIFormationInfo;

	UniverseID GetPlayerID(void);
	bool IsGamePaused(void);

	bool GetOrderDefinition(OrderDefinition* result, const char* orderdef);
	const char* GetObjectIDCode(UniverseID objectid);
	bool IsComponentClass(UniverseID componentid, const char* classname);
	bool IsComponentOperational(UniverseID componentid);
	bool IsComponentWrecked(UniverseID componentid);
	uint32_t GetNumCargoTransportTypes(UniverseID containerid, bool merge);
	uint32_t GetCargoTransportTypes(StorageInfo* result, uint32_t resultlen, UniverseID containerid, bool merge, bool aftertradeorders);
	size_t GetOrderQueueFirstLoopIdx(UniverseID controllableid, bool* isvalid);
  uint32_t GetOrders(Order* result, uint32_t resultlen, UniverseID controllableid);
	uint32_t CreateOrder(UniverseID controllableid, const char* orderid, bool default);
	bool EnablePlannedDefaultOrder(UniverseID controllableid, bool checkonly);
	bool SetOrderLoop(UniverseID controllableid, size_t orderidx, bool checkonly);
	bool EnableOrder(UniverseID controllableid, size_t idx);
	uint32_t GetNumDiscoveredSectorResources(UniverseID sectorid);
	uint32_t GetDiscoveredSectorResources(WareYield* result, uint32_t resultlen, UniverseID sectorid);
	uint32_t GetNumFormationShapes(void);
	uint32_t GetFormationShapes(UIFormationInfo* result, uint32_t resultlen);
]]

local StandingOrders = {
  args = {},
  playerId = 0,
  configBlackboard = "$StandingOrdersConfig",
  debugLevel = "none", -- "none" = off, "debug" = one line per action, "trace" = per-item detail
  mapMenu = {},
  orderDefs = {},
  loopOrdersSkillLimit = 0,
  sourceId = 0,
  targetIds = {},
  -- Editable copy of the source queue: rendered by the dialog, applied to the targets on confirm.
  staged = {},
  showAdvanced = false,
  applyToSource = false,
  queueTable = nil,
  queueTopRow = nil,
  dialogRefreshQueued = false,
  rebuilding = false,
  paused = false,
  -- Ships whose queue the engine refuses to clear, keyed by tostring(id).
  blocked = {},
  sourceBlocked = false,
  -- Set while a value picker replaces the dialog; nil means the dialog itself is showing.
  ---@type table?
  picker = nil,
  -- Set while the player is picking an object or a position on the map, with the dialog taken down.
  ---@type table?
  picking = nil,
}

-- Param types the dialog can edit in place. The rest render as vanilla does but stay inactive.
local inlineEditableTypes = {
  bool = true,
  number = true,
  length = true,
  time = true,
  money = true,
}

-- Param types a picker frame can supply a value for, either directly or as a list element type.
local pickableTypes = {
  ware = true,
  sector = true,
  formationshape = true,
}

-- Param types picked by clicking the map instead, through vanilla's own orderparam modes.
local mapPickableTypes = {
  object = true,
  position = true,
}

-- Picker frame titles, taken from the vanilla contexts these are ports of.
local pickerTitles = {
  ware = { single = 8306, list = 8376 },
  sector = { single = 11238, list = 9177 },
  formationshape = { single = 8307, list = 8307 },
}

local pickerWidth = 350


local Lib = require("extensions.sn_mod_support_apis.ui.Library")

-- Messages are often built by concatenation, so only format when args are actually passed:
-- a ship name containing a percent sign would otherwise break string.format.
local function write(message, ...)
  if select("#", ...) > 0 then
    message = string.format(message, ...)
  end
  DebugError("StandingOrders: " .. message)
end

function StandingOrders.Error(message, ...)
  write(message, ...)
end

function StandingOrders.Debug(message, ...)
  if StandingOrders.debugLevel == "debug" or StandingOrders.debugLevel == "trace" then
    write(message, ...)
  end
end

function StandingOrders.Trace(message, ...)
  if StandingOrders.debugLevel == "trace" then
    write(message, ...)
  end
end

-- The MD event may arrive before or after the config exists, so the blackboard is the fallback source on load.
function StandingOrders.ReadDebugLevel()
  if StandingOrders.playerId == 0 then
    return
  end
  local config = GetNPCBlackboard(StandingOrders.playerId, StandingOrders.configBlackboard)
  if config and config.debugLevel then
    StandingOrders.debugLevel = tostring(config.debugLevel)
  end
  StandingOrders.Debug("ReadDebugLevel: level: %s", StandingOrders.debugLevel)
end

function StandingOrders.SetDebugLevel(_, level)
  if level and level ~= "" then
    StandingOrders.debugLevel = tostring(level)
    StandingOrders.Debug("SetDebugLevel: level: %s", StandingOrders.debugLevel)
  else
    StandingOrders.ReadDebugLevel()
  end
end

local function getPlayerId()
  local current = C.GetPlayerID()
  if current == nil or current == 0 then
    return
  end

  local converted = ConvertStringTo64Bit(tostring(current))
  if converted ~= 0 and converted ~= StandingOrders.playerId then
    StandingOrders.Trace("updating player_id to " .. tostring(converted))
    StandingOrders.playerId = converted
  end
end

local function toUniverseId(value)
  if value == nil then
    return 0
  end

  if type(value) == "number" then
    return value
  end

  local idStr = tostring(value)
  if idStr == "" or idStr == "0" then
    return 0
  end

  return ConvertStringTo64Bit(idStr)
end

local function copyAndEnrichTable(src, extraInfo)
  local dest = {}
  for k, v in pairs(src) do
    dest[k] = v
  end
  for k, v in pairs(extraInfo) do
    dest[k] = v
  end
  return dest
end

local function getShipName(shipId)
  if shipId == 0 or not IsValidComponent(shipId) then
    return "Unknown"
  end
  local name = GetComponentData(ConvertStringToLuaID(tostring(shipId)), "name")
  if not name then
    return "Unknown"
  end
  -- GetObjectIDCode returns NULL for a component that died since the id was cached
  local idCodePtr = C.GetObjectIDCode(shipId)
  local idCode = (idCodePtr ~= nil) and ffi.string(idCodePtr) or ""
  return string.format("%s (%s)", name, idCode)
end

-- Resolved lazily: any order the engine knows, not a curated whitelist.
local function getOrderDef(orderDef)
  local cached = StandingOrders.orderDefs[orderDef]
  if cached == nil then
    cached = { name = orderDef, icon = "" }
    local buf = ffi.new("OrderDefinition")
    if C.GetOrderDefinition(buf, orderDef) then
      cached.name = ffi.string(buf.name)
      cached.icon = ffi.string(buf.icon)
    else
      StandingOrders.Debug("order definition " .. tostring(orderDef) .. " could not be resolved")
    end
    StandingOrders.orderDefs[orderDef] = cached
  end
  return cached
end

local function findWareTransportType(orderParams)
  for i = 1, #orderParams do
    local p = orderParams[i]
    if p.type == "ware" and p.value ~= nil then
      return GetWareData(p.value, "transport")
    end
  end
  return nil
end

-- True when a numeric param's own bound equals the ship's capacity for the order's ware -- i.e.
-- it is a cargo-amount param, not an order-fixed bound like radius.
local function isCargoBoundParam(paramData, sourceCapacity)
  return paramData.type == "number" and sourceCapacity ~= nil
      and paramData.inputparams ~= nil and paramData.inputparams.max ~= nil
      and math.abs(paramData.inputparams.max - sourceCapacity) <= 0.01
end

local function centerFrameVertically(frame)
  frame.properties.height = frame:getUsedHeight() + Helper.borderSize
  if (frame.properties.height > Helper.viewHeight ) then
    frame.properties.y = Helper.borderSize
    frame.properties.height = Helper.viewHeight - 2 * Helper.borderSize
  else
    frame.properties.y = (Helper.viewHeight - frame.properties.height) / 2
  end
end

function StandingOrders.recordResult()
  local data = StandingOrders.args or {}
  StandingOrders.Trace("recordResult called for command ".. tostring(data and data.command) .. " with result " .. tostring(data and data.result))
  if StandingOrders.playerId ~= 0 then
    local payload = data or {}
    SetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersResponse", payload)
    AddUITriggeredEvent("StandingOrders", "Response")
  end
end

function StandingOrders.reportError(extraInfo)
  local data = StandingOrders.args or {}
  data.result = "error"
  if extraInfo == nil then
    extraInfo = {}
  end
  for k, v in pairs(extraInfo) do
    data[k] = v
  end
  StandingOrders.recordResult()

  local message = "error"
  if data.info then
    message = message .. ": " .. tostring(data.info)
  end
  if data.detail then
    message = message .. " (" .. tostring(data.detail) .. ")"
  end

  StandingOrders.Error(message)
end

function StandingOrders.reportSuccess(extraStatus)
  data = StandingOrders.args or {}
  data.result = extraStatus or "success"
  StandingOrders.recordResult()
end

function StandingOrders.isLoopEnabled(shipId)
  local shipId = toUniverseId(shipId)
  local hasLoop = ffi.new("bool[1]", false)
  local firstLoop = tonumber(C.GetOrderQueueFirstLoopIdx(shipId, hasLoop))
  return hasLoop[0]
end

function StandingOrders.getStandingOrders(shipId)
  local shipId = toUniverseId(shipId)
  local numOrders = tonumber(C.GetNumOrders(shipId)) or 0
  local buf = ffi.new("Order[?]", numOrders)
  local count = tonumber(C.GetOrders(buf, numOrders, shipId)) or 0
  local orders = {}
  for i = 0, numOrders - 1 do
    local orderData = buf[i]
    if (tonumber(orderData.queueidx) > 0 and ffi.string(orderData.orderdef) ~= "" and orderData.enabled and not orderData.istemporder) then
      local order = {
        idx = tonumber(orderData.queueidx),
        order = ffi.string(orderData.orderdef),
      }
      orders[#orders + 1] = order
    end
  end
  return orders
end

-- transportTypes is only supplied when the source queue actually carries wares; a queue of
-- non-trade orders imposes no cargo requirement on its targets.
function StandingOrders.checkShip(shipId, transportTypes)
  local shipId = toUniverseId(shipId)
  if shipId == 0 or not IsValidComponent(shipId) then
    return false, { info = "InvalidShipID" }
  end
  local isShip = C.IsComponentClass(shipId, "ship")
  if not isShip then
    return false, { info = "NotAShip" }
  end
  local owner = GetComponentData(shipId, "owner")
  if owner ~= "player" then
    return false, { info = "NotPlayerShip", detail = "owner=" .. tostring(owner) }
  end
  if not C.IsComponentOperational(shipId) or C.IsComponentWrecked(shipId) then
    return false, { info = "ShipNotOperational" }
  end
  if type(transportTypes) == "table" then
    for i = 1, #transportTypes do
      if StandingOrders.getCargoCapacity(shipId, transportTypes[i]) == 0 then
        return false, { info = "NoCargoCapacity", detail = "transport=" .. tostring(transportTypes[i]) }
      end
    end
  end
  return true
end

-- An order in a critical state cannot be removed, and RemoveAllOrders then clears nothing at all.
-- RemoveOrder in checkonly mode is the same question ego asks to grey out its own remove button.
function StandingOrders.canClearOrders(shipId)
  local shipId = toUniverseId(shipId)
  local numOrders = tonumber(C.GetNumOrders(shipId)) or 0
  for i = 1, numOrders do
    if not C.RemoveOrder(shipId, i, false, true) then
      return false
    end
  end
  return true
end

function StandingOrders.isBlocked(shipId)
  return StandingOrders.blocked[tostring(shipId)] == true
end

-- The dialog stages edits against a queue snapshot, so the world must not move underneath it.
function StandingOrders.ensurePaused()
  if StandingOrders.paused or C.IsGamePaused() then
    return
  end
  StandingOrders.paused = true
  Pause()
end

function StandingOrders.releasePause()
  if not StandingOrders.paused then
    return
  end
  StandingOrders.paused = false
  Unpause()
end

function StandingOrders.getCargoCapacity(shipId, transportType)
  local menu = StandingOrders.mapMenu
  local shipId = toUniverseId(shipId)
  if transportType == nil then
    return 0
  end
  local numStorages = C.GetNumCargoTransportTypes(shipId, true)
  local buf = ffi.new("StorageInfo[?]", numStorages)
  local count = C.GetCargoTransportTypes(buf, numStorages, shipId, true, false)
  local capacity = 0
  for i = 0, count - 1 do
    local tags = menu.getTransportTagsFromString(ffi.string(buf[i].transport))
    if tags[transportType] == true then
      capacity = capacity + buf[i].capacity
    end
  end
  return capacity
end


function StandingOrders.isValidSourceShip()
  local sourceId = toUniverseId(StandingOrders.args.source)
  local valid, errorData = StandingOrders.checkShip(sourceId)
  if not valid then
    return false, errorData
  end
  if StandingOrders.isLoopEnabled(sourceId) == false then
    return false, { info = "LoopNotEnabled" }
  end
  local orders = StandingOrders.getStandingOrders(sourceId)
  if #orders == 0 then
    return false, { info = "NoStandingOrders" }
  end
  return true
end

function StandingOrders.isValidTargetShip(target, transportTypes)
  local targetId = toUniverseId(target)
  local valid, errorData = StandingOrders.checkShip(targetId, transportTypes)
  if not valid then
    return false, errorData
  end
  local loopSkill = StandingOrders.loopOrdersSkillLimit
  local aiPilot = GetComponentData(ConvertStringToLuaID(tostring(targetId)), "assignedaipilot")
  local aiPilotSkill = aiPilot and math.floor(C.GetEntityCombinedSkill(ConvertIDTo64Bit(aiPilot), nil, "aipilot") * 15 / 100) or -1
  if aiPilotSkill < loopSkill then
    return false, { info = "TargetPilotSkillTooLow", detail = "skill=" .. tostring(aiPilotSkill) .. ", required=" .. tostring(loopSkill) }
  end
  return true
end


function StandingOrders.getArgs()
  StandingOrders.args = {}
  if StandingOrders.playerId == 0 then
    StandingOrders.Debug("getArgs unable to resolve player id")
  else
    local list = GetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersRequest")
    if type(list) == "table" then
      StandingOrders.Trace("getArgs retrieved " .. tostring(#list) .. " entries from blackboard")
      StandingOrders.args = list[#list]
      SetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersRequest", nil)
      return true
    elseif list ~= nil then
      StandingOrders.Debug("getArgs received non-table payload of type " .. type(list))
    else
      StandingOrders.Trace("getArgs found no blackboard entries for player " .. tostring(StandingOrders.playerId))
    end
  end
  return false
end


function StandingOrders.MarkSourceOnMap()
  local source = tostring(StandingOrders.args.source)
  local args = StandingOrders.args or {}
  if not source or source == "" then
    StandingOrders.reportError({ info = "InvalidSourceID" })
    return
  end

  StandingOrders.Trace("MapMenu is " .. tostring(StandingOrders.mapMenu) .. " for source " .. source)
  if StandingOrders.mapMenu and StandingOrders.mapMenu.holomap and (StandingOrders.mapMenu.holomap ~= 0) then
    StandingOrders.mapMenu.selectedcomponents = {}
    if (args.command == "unmark_source") then
      args.info = "SourceUnmarked"
    else
      args.info = "SourceMarked"
      StandingOrders.mapMenu.selectedcomponents[source] = true
    end
    StandingOrders.mapMenu.refreshInfoFrame()
  else
    args.info = "NoMap"
    StandingOrders.reportError()
    return
  end
  StandingOrders.reportSuccess()
end


function StandingOrders.showSourceAlert(errorData)

  local sourceId = toUniverseId(StandingOrders.args.source)

  local sourceName = getShipName(sourceId)
  local options = {}
  options.title = ReadText(1972092408, 10110)
  local details = "error"
  if errorData and type(errorData) == "table" and errorData.info then
    if errorData.info == "InvalidShipID" then
      details = ReadText(1972092408, 10121)
    elseif errorData.info == "NotAShip" then
      details = ReadText(1972092408, 10122)
    elseif errorData.info == "NotPlayerShip" then
      details = ReadText(1972092408, 10123)
    elseif errorData.info == "ShipNotOperational" then
      details = ReadText(1972092408, 10124)
    elseif errorData.info == "NoCargoCapacity" then
      details = ReadText(1972092408, 10125)
    elseif errorData.info == "LoopNotEnabled" then
      details = ReadText(1972092408, 10131)
    elseif errorData.info == "NoStandingOrders" then
      details = ReadText(1972092408, 10132)
    end
  end
  local message = string.format(ReadText(1972092408, 10111), sourceName, details)
  options.message = message

  StandingOrders.alertMessage(options)
end


function StandingOrders.alertMessage(options)
  local menu = StandingOrders.mapMenu
  if type(menu) ~= "table" or type(menu.closeContextMenu) ~= "function" then
    StandingOrders.Debug("alertMessage: Invalid menu instance")
    return false, "Map menu instance is not available"
  end
  if type(Helper) ~= "table" then
    StandingOrders.Debug("alertMessage: Helper UI utilities are not available")
    return false, "Helper UI utilities are not available"
  end

  if type(options) ~= "table" then
    return false, "Options parameter is not a table"
  end

  if options.title == nil then
    return false, "Title option is required"
  end

  if options.message == nil then
    return false, "Message option is required"
  end

  local width = options.width or Helper.scaleX(400)
  local xoffset = options.xoffset or (Helper.viewWidth - width) / 2
  local yoffset = options.yoffset or Helper.viewHeight / 2
  local okLabel = options.okLabel or ReadText(1001, 14)

  local title = options.title
  local message = options.message

  menu.closeContextMenu()

  menu.contextMenuMode = "standing_orders_alert"
  menu.contextMenuData = {
    mode = "standing_orders_alert",
    width = width,
    xoffset = xoffset,
    yoffset = yoffset,
  }

  local contextLayer = menu.contextFrameLayer or 2

  menu.contextFrame = Helper.createFrameHandle(menu, {
    x = xoffset - 2 * Helper.borderSize,
    y = yoffset,
    width = width + 2 * Helper.borderSize,
    layer = contextLayer,
    standardButtons = { close = true },
    closeOnUnhandledClick = true,
  })
  local frame = menu.contextFrame
  frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

  local ftable = frame:addTable(5, { tabOrder = 1, x = Helper.borderSize, y = Helper.borderSize, width = width, reserveScrollBar = false, highlightMode = "off" })

  local headerRow = ftable:addRow(false, { fixed = true })
  headerRow[1]:setColSpan(5):createText(title, copyAndEnrichTable(Helper.headerRowCenteredProperties, { color = Color["text_warning"] }))

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local messageRow = ftable:addRow(false, { fixed = true })
  messageRow[1]:setColSpan(5):createText(message, {
    halign = "center",
    wordwrap = true,
    color = Color["text_normal"]
  })

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local buttonRow = ftable:addRow(true, { fixed = true })
  buttonRow[3]:createButton():setText(okLabel, { halign = "center" })
  buttonRow[3].handlers.onClick = function ()
    local shouldClose = true
    if shouldClose then
      menu.closeContextMenu("back")
    end
  end
  ftable:setSelectedCol(3)

  centerFrameVertically(frame)

  frame:display()

  return true
end

function StandingOrders.showTargetAlert()
  local options = {}
  options.title = ReadText(1972092408, 10310)
  options.message = ReadText(1972092408, 10311)
  StandingOrders.alertMessage(options)
end


-- getParamValue covers every param type the engine emits, but dereferences live objects that can
-- vanish while the dialog is open.
local function safeParamValue(valueType, value, inputparams)
  local ok, result = pcall(StandingOrders.mapMenu.getParamValue, valueType, value, inputparams)
  if not ok or result == nil then
    return tostring(value)
  end
  return result
end

-- The engine forbids the player setting these regardless of what we are staging.
local function isParamLocked(param)
  if param.inputparams and param.inputparams.playerreadonly then
    return param.inputparams.playerreadonly == 1
  end
  if param.playerreadonly then
    return param.playerreadonly == 1
  end
  return false
end

-- Snapshot of the source queue taken once, up front: every later read comes from here, so nothing
-- we do to a target's queue can invalidate what still has to be applied.
function StandingOrders.buildStagedQueue(sourceId)
  local staged = {}
  local orders = StandingOrders.getStandingOrders(sourceId)
  for i = 1, #orders do
    local order = orders[i]
    local params = GetOrderParams(sourceId, order.idx) or {}
    local hasParams = false
    for j = 1, #params do
      if params[j].type ~= "internal" then
        hasParams = true
        break
      end
    end
    staged[#staged + 1] = {
      sourceIdx = order.idx,
      orderdef = order.order,
      def = getOrderDef(order.order),
      params = params,
      hasParams = hasParams,
      expanded = true,
    }
  end
  return staged
end

-- Both derive from the staged ware params, which a picker can change, so they are recomputed
-- whenever the dialog is rebuilt or the queue applied rather than cached from the snapshot.
function StandingOrders.refreshStagedCapacities()
  for i = 1, #StandingOrders.staged do
    local entry = StandingOrders.staged[i]
    entry.transportType = findWareTransportType(entry.params)
    entry.sourceCapacity = entry.transportType and StandingOrders.getCargoCapacity(StandingOrders.sourceId, entry.transportType) or nil
  end
end

function StandingOrders.stagedTransportTypes()
  local seen = {}
  local list = {}
  for i = 1, #StandingOrders.staged do
    local transportType = findWareTransportType(StandingOrders.staged[i].params)
    if transportType ~= nil and seen[transportType] == nil then
      seen[transportType] = true
      list[#list + 1] = transportType
    end
  end
  return list
end

-- ftable.id is only valid while the table is displayed, so the scroll position has to be read
-- before anything tears the dialog down -- never from the deferred rebuild.
function StandingOrders.rememberQueueScroll()
  local queueTable = StandingOrders.queueTable
  if queueTable and queueTable.id then
    StandingOrders.queueTopRow = GetTopRow(queueTable.id)
  end
end

-- Rebuilding the frame from inside a widget callback fights closeOnUnhandledClick and the pending
-- frame teardown, so every mutation defers the rebuild by one update, as ego does for its own
-- context refreshes. The same deferral swaps between the dialog and a value picker, since the map
-- menu only ever holds one context frame.
function StandingOrders.refreshCloneDialog()
  StandingOrders.rememberQueueScroll()
  if StandingOrders.dialogRefreshQueued then
    return
  end
  StandingOrders.dialogRefreshQueued = true
  Helper.addDelayedOneTimeCallbackOnUpdate(function ()
    StandingOrders.dialogRefreshQueued = false
    if StandingOrders.picking then
      -- A map pick has the dialog down on purpose; it comes back when the mode ends.
      return
    end
    if StandingOrders.sourceId ~= 0 then
      -- The rebuild tears the old frame down and puts an identical one up; that is not the dialog
      -- going away, so the pause must survive it.
      StandingOrders.rebuilding = true
      if StandingOrders.picker then
        StandingOrders.showParamPicker()
      else
        StandingOrders.cloneOrdersConfirm()
      end
      StandingOrders.rebuilding = false
    else
      -- Nothing left to show: the pause would otherwise have no owner to release it.
      StandingOrders.picker = nil
      StandingOrders.releasePause()
    end
  end, false, 0)
end

function StandingOrders.buttonStagedExpand(entry)
  entry.expanded = not entry.expanded
  StandingOrders.refreshCloneDialog()
end

function StandingOrders.buttonStagedOrderMove(idx, offset)
  local staged = StandingOrders.staged
  local target = idx + offset
  if target < 1 or target > #staged then
    return
  end
  staged[idx], staged[target] = staged[target], staged[idx]
  StandingOrders.refreshCloneDialog()
end

function StandingOrders.buttonStagedOrderRemove(idx)
  table.remove(StandingOrders.staged, idx)
  StandingOrders.refreshCloneDialog()
end

function StandingOrders.checkboxStagedParam(param)
  param.value = (param.value ~= 0) and 0 or 1
end

-- The element type of a list param, or the param's own type otherwise -- what a picker must supply.
local function pickerKind(param)
  if param.type == "list" then
    return param.inputparams and param.inputparams.type
  end
  return param.type
end

-- How a value for this param can be obtained: "frame" from an own picker frame, "map" by clicking
-- the map, nil if the dialog cannot supply one.
local function pickMode(param)
  if isParamLocked(param) then
    return nil
  end
  local kind = pickerKind(param)
  if pickableTypes[kind] then
    return "frame"
  end
  if mapPickableTypes[kind] then
    return "map"
  end
  return nil
end

-- Sector values travel as Lua IDs; the selection map is keyed by the 64-bit form so a value read
-- back from GetOrderParams and one built here compare equal.
local function pickerKey(kind, value)
  if kind == "sector" then
    return tostring(ConvertIDTo64Bit(value))
  end
  return tostring(value)
end

function StandingOrders.buttonOpenPicker(param)
  StandingOrders.picker = { param = param, kind = pickerKind(param), islist = param.type == "list" }
  StandingOrders.refreshCloneDialog()
end

function StandingOrders.buttonClosePicker()
  StandingOrders.picker = nil
  StandingOrders.refreshCloneDialog()
end

-- Port of the object and position branches of menu.buttonSetOrderParam (menu_map.lua:2976, 3128).
-- Vanilla's mode machinery does the entire map-side job -- object filter, cursor, top-level banner,
-- every cancel route -- off menu.mode plus menu.modeparam, so the only piece that is ours is
-- modeparam[1]. The engine filter is keyed on the source's own order, which the staged entry is
-- still a copy of; nothing has touched the source queue at this point.
function StandingOrders.buttonStartMapPick(entry, paramIdx, param, listIdx)
  local menu = StandingOrders.mapMenu
  if (menu.holomap == nil) or (menu.holomap == 0) then
    StandingOrders.Debug("buttonStartMapPick: no holomap to pick on")
    return
  end

  StandingOrders.picking = { param = param, listIdx = listIdx }
  -- The pick does not go through refreshCloneDialog, so the scroll position has to be taken here.
  StandingOrders.rememberQueueScroll()
  StandingOrders.queueTable = nil

  -- Slots 5 and 6 are the order coordinates the object filter needs; position mode leaves them unset
  -- as vanilla does, and slot 5 must stay a number so ego does not read it as a default order.
  local isObject = pickerKind(param) == "object"
  local orderIdx, paramSlot
  if isObject then
    orderIdx, paramSlot = entry.sourceIdx, paramIdx
  end
  local controllable = ConvertStringToLuaID(tostring(StandingOrders.sourceId))
  menu.currentInfoMode = { menu.infoTableMode, menu.infoMode.left }
  menu.modeparam = { StandingOrders.setMapPickValue, param, 1, controllable, orderIdx, paramSlot }
  menu.settoprow = 0
  menu.setMouseCursorOverride("target", 3)

  if isObject then
    menu.infoTableMode = "objectlist"
    menu.mode = "orderparam_object"
    C.SetMapOrderParamObjectFilter(menu.holomap, StandingOrders.sourceId, orderIdx, paramSlot)
    menu.closeContextMenu()
    menu.refreshInfoFrame()
    menu.refreshMainFrame = true
  else
    menu.mode = "orderparam_position"
    menu.closeContextMenu()
    menu.refreshInfoFrame()
  end
end

-- Counterpart of menu.setOrderParamFromMode: write into the staged param instead of a live order,
-- then let vanilla tear its own mode down -- the reset hook is what brings the dialog back.
function StandingOrders.setMapPickValue(value)
  local picking = StandingOrders.picking
  if picking then
    local param = picking.param
    -- The map hands a position back as {ref, {x, y, z}} while GetOrderParams uses {ref, {x=, y=,
    -- z=}}; the staged queue holds one shape only.
    if pickerKind(param) == "position" then
      value = { value[1], { x = value[2][1], y = value[2][2], z = value[2][3] } }
    end
    if param.type == "list" then
      param.value = param.value or {}
      if picking.listIdx then
        param.value[picking.listIdx] = value
      else
        param.value[#param.value + 1] = value
      end
    else
      param.value = value
    end
  end
  StandingOrders.mapMenu.resetOrderParamMode()
end

function StandingOrders.buttonEditStagedParam(mode, entry, paramIdx, param, listIdx)
  if mode == "frame" then
    StandingOrders.buttonOpenPicker(param)
  elseif mode == "map" then
    StandingOrders.buttonStartMapPick(entry, paramIdx, param, listIdx)
  end
end

function StandingOrders.buttonRemoveStagedListParam(param, listIdx)
  table.remove(param.value, listIdx)
  StandingOrders.refreshCloneDialog()
end

function StandingOrders.buttonPickerSetValue(value)
  local picker = StandingOrders.picker
  if picker then
    picker.param.value = value
  end
  StandingOrders.buttonClosePicker()
end

-- Ego re-adds a whole list rather than patching it, to keep it alphabetical; the staged list is
-- rebuilt the same way, in the option order the picker already sorted.
function StandingOrders.buttonPickerSetList()
  local picker = StandingOrders.picker
  if picker then
    local values = {}
    for i = 1, #picker.options do
      local option = picker.options[i]
      if picker.selected[option.key] then
        values[#values + 1] = option.value
      end
    end
    picker.param.value = values
  end
  StandingOrders.buttonClosePicker()
end

function StandingOrders.checkboxPickerOption(key, checked)
  StandingOrders.picker.selected[key] = checked or nil
end

function StandingOrders.checkboxPickerToggleAll(checked)
  local picker = StandingOrders.picker
  picker.selected = {}
  if checked then
    for i = 1, #picker.options do
      picker.selected[picker.options[i].key] = true
    end
  end
end

function StandingOrders.pickerNumSelected()
  local count = 0
  for _ in pairs(StandingOrders.picker.selected) do
    count = count + 1
  end
  return count
end

function StandingOrders.isPickerSelectionChanged()
  local picker = StandingOrders.picker
  for key in pairs(picker.selected) do
    if not picker.origSelected[key] then
      return true
    end
  end
  for key in pairs(picker.origSelected) do
    if not picker.selected[key] then
      return true
    end
  end
  return false
end

-- Sliders show length in km and time in minutes; the staged value stays in the scale
-- GetOrderParams returned, which is what cloneOrdersExecute expects. Money is the exception:
-- both are in display scale and the x100 happens on apply.
function StandingOrders.slidercellStagedParam(param, value)
  if value == nil then
    return
  end
  if param.type == "length" then
    if param.inputparams.step >= 1000 then
      value = value * 1000
    end
  elseif param.type == "time" then
    value = value * 60
  end
  param.value = value
end

-- Port of menu.displayOrderParam (menu_map.lua:10142) in its hasloop layout: same widgets, same
-- columns, but every handler writes into the staged param instead of a live order. listParam is the
-- owning list param when this row renders one of its entries -- it, not the synthetic entry param,
-- is what an editor edits.
function StandingOrders.addStagedParamRow(zipper, entry, paramIdx, param, listIdx, listParam)
  local value = param.value
  local ismissing = value == nil
  local active = (not isParamLocked(param)) and (inlineEditableTypes[param.type] == true)

  if not ismissing then
    value = safeParamValue(param.type, value, param.inputparams)
  end

  local paramcolor = ismissing and Color["text_error"] or Color["text_normal"]
  local paramtext = (param.text ~= "") and ("  " .. param.text .. ReadText(1001, 120)) or ""

  if listIdx then
    -- A picker frame edits the list as a whole, a map pick one entry at a time -- so the frame route
    -- ignores listIdx and the map route carries it, exactly as vanilla splits them.
    local mode = pickMode(listParam)
    local row = zipper.add(true, {  })
    row[4]:createText(paramtext)
    row[5]:setColSpan(7):createButton({ active = mode ~= nil }):setText(value and tostring(value) or "", { halign = "center", color = paramcolor })
    row[5].handlers.onClick = function () return StandingOrders.buttonEditStagedParam(mode, entry, paramIdx, listParam, listIdx) end
    row[12]:createButton({ active = (mode ~= nil) and ((not listParam.required) or (#listParam.value > 1)) }):setText("x", { halign = "center", color = paramcolor })
    row[12].handlers.onClick = function () return StandingOrders.buttonRemoveStagedListParam(listParam, listIdx) end
  elseif param.inputparams and (param.type == "number" or param.type == "length" or param.type == "time" or param.type == "money") then
    local defaultmax = 50000
    local minselect = math.max(0, param.inputparams.min or 0)
    local maxselect = math.max(0, param.inputparams.max or defaultmax)
    local curvalue = tonumber(param.value)
    local startvalue = param.inputparams.startvalue
    local step = (param.inputparams.step and (param.inputparams.step >= 1)) and param.inputparams.step or 1
    local usetimeformat = false

    local suffix = ""
    if param.type == "length" then
      if param.inputparams.step >= 1000 then
        suffix = ReadText(1001, 108)
        minselect = math.floor(minselect / 1000)
        maxselect = math.floor(maxselect / 1000)
        curvalue = curvalue and math.floor(curvalue / 1000)
        startvalue = startvalue and math.floor(startvalue / 1000)
        step = math.ceil(step / 1000)
      else
        suffix = ReadText(1001, 107)
      end
    elseif param.type == "time" then
      suffix = ReadText(1001, 103)
      usetimeformat = true
      minselect = math.floor(minselect / 60)
      maxselect = math.floor(maxselect / 60)
      curvalue = curvalue and math.floor(curvalue / 60)
      startvalue = startvalue and math.floor(startvalue / 60)
      step = math.ceil(step / 60)
    elseif param.type == "money" then
      suffix = ReadText(1001, 101)
    end

    local infinitevalue
    local useinfinite = false
    if param.hasinfinitevalue then
      useinfinite = true
      infinitevalue = param.infinitevalue
    end

    local slidercellProperties = {
      height = Helper.standardTextHeight,
      bgColor = Color["slider_background_transparent"],
      valueColor = active and Color["slider_value"] or Color["slider_value_inactive"],
      min = minselect,
      max = maxselect,
      start = math.max(minselect, math.min(maxselect, curvalue or startvalue or minselect)),
      step = step,
      suffix = suffix,
      exceedMaxValue = false,
      readOnly = not active,
      hideMaxValue = param.hasinfinitevalue,
      useInfiniteValue = useinfinite,
      infiniteValue = infinitevalue,
      useTimeFormat = usetimeformat,
    }

    -- The share of the hold this order books is what actually carries over to a target, since the
    -- amount itself is rescaled to each target's capacity.
    local mouseOverText
    local sourceCapacity = entry.sourceCapacity
    if isCargoBoundParam(param, sourceCapacity) and sourceCapacity > 0 and param.value then
      mouseOverText = string.format("%.2f%%", param.value * 100 / sourceCapacity)
    end

    local row = zipper.add(true, {  })
    row[4]:createText(paramtext, { mouseOverText = mouseOverText })
    row[5]:setColSpan(8):createSliderCell(slidercellProperties):setText("", { fontsize = Helper.standardFontSize, color = paramcolor })
    row[5].handlers.onSliderCellConfirm = function (_, newvalue) return StandingOrders.slidercellStagedParam(param, newvalue) end
    row[5].handlers.onSliderCellActivated = function () StandingOrders.mapMenu.noupdate = true end
    row[5].handlers.onSliderCellDeactivated = function () StandingOrders.mapMenu.noupdate = false end
  elseif param.type == "bool" then
    local row = zipper.add(true, {  })
    row[4]:createText(paramtext)
    row[5]:createCheckBox(function () return param.value ~= nil and param.value ~= 0 end, { active = active, width = Helper.standardTextHeight })
    row[5].handlers.onClick = function () return StandingOrders.checkboxStagedParam(param) end
  else
    local mode = pickMode(param)
    local row = zipper.add(true, {  })
    row[4]:createText(paramtext)
    row[5]:setColSpan(8)
    local text = value and tostring(value) or (ColorText["text_inactive"] .. ReadText(1001, 3102) .. "...")
    local height = math.max(Helper.standardTextHeight, math.ceil(C.GetTextHeight(text, Helper.standardFont, Helper.standardFontSize, row[5]:getWidth())) + Helper.borderSize)
    row[5]:createButton({ active = mode ~= nil, height = height }):setText(text, { halign = "center", color = paramcolor, y = (height - Helper.standardTextHeight) / 2 })
    row[5].handlers.onClick = function () return StandingOrders.buttonEditStagedParam(mode, entry, paramIdx, param, nil) end
  end
end

-- Port of the order-row half of menu.createOrderQueue (menu_map.lua:11344).
function StandingOrders.addStagedOrderRows(zipper)
  local staged = StandingOrders.staged
  for i = 1, #staged do
    local entry = staged[i]

    local row = zipper.add(true, {  })
    row[2]:createButton({ active = entry.hasParams }):setText(entry.expanded and "-" or "+", { halign = "center" })
    row[2].handlers.onClick = function () return StandingOrders.buttonStagedExpand(entry) end
    row[3]:createText(i, { halign = "right" })
    row[4]:setColSpan(5):createText(entry.def.name, { x = 0 })
    row[10]:createButton({ active = i > 1, mouseOverText = ReadText(1026, 3264) }):setIcon("table_arrow_inv_up")
    row[10].handlers.onClick = function () return StandingOrders.buttonStagedOrderMove(i, -1) end
    row[11]:createButton({ active = i < #staged, mouseOverText = ReadText(1026, 3265) }):setIcon("table_arrow_inv_down")
    row[11].handlers.onClick = function () return StandingOrders.buttonStagedOrderMove(i, 1) end
    row[12]:createButton({ active = #staged > 1, mouseOverText = ReadText(1026, 3263) }):setText("x", { halign = "center" })
    row[12].handlers.onClick = function () return StandingOrders.buttonStagedOrderRemove(i) end

    if entry.expanded then
      for j = 1, #entry.params do
        local param = entry.params[j]
        if (not param.advanced) or StandingOrders.showAdvanced then
          if param.type == "list" then
            param.value = param.value or {}
            for k = 1, #param.value do
              local param2 = {
                text = (k == 1) and param.text or "",
                value = param.value[k],
                type = param.inputparams.type,
                editable = param.editable,
                playerreadonly = param.inputparams and param.inputparams.playerreadonly,
              }
              StandingOrders.addStagedParamRow(zipper, entry, j, param2, k, param)
            end
            -- No listIdx on the add row: a map pick appends there, where an entry row replaces.
            local mode = pickMode(param)
            local addRow = zipper.add(true, {  })
            addRow[2]:setColSpan(11):createButton({ active = mode ~= nil }):setText("  " .. string.format(ReadText(1001, 3235), param.text), { halign = "center" })
            addRow[2].handlers.onClick = function () return StandingOrders.buttonEditStagedParam(mode, entry, j, param, nil) end
          elseif param.type ~= "internal" then
            StandingOrders.addStagedParamRow(zipper, entry, j, param, nil)
          end
        end
      end
    end
  end
end

-- Option lists mirror ego's own pickers: createOrderparamWareContext (menu_map.lua:20760),
-- createOrderparamSectorContext (20863) and createOrderparamFormationShapeContext (21049). None of
-- them reads a live order, only param.inputparams -- which is what makes staged editing possible.
function StandingOrders.buildPickerOptions(kind, inputparams)
  local options = {}
  if kind == "ware" then
    local wares = Helper.getOrderParameterWares(inputparams or {})
    for i = 1, #wares do
      options[i] = { key = wares[i], value = wares[i], name = GetWareData(wares[i], "name") }
    end
  elseif kind == "sector" then
    local needed
    if inputparams and inputparams.hasresources then
      needed = {}
      for _, ware in ipairs(inputparams.hasresources) do
        needed[ware] = true
      end
    end
    local sectorIds = {}
    for _, cluster in ipairs(GetClusters(true)) do
      for _, sector in ipairs(GetSectors(cluster)) do
        local sector64 = ConvertIDTo64Bit(sector)
        if needed == nil then
          sectorIds[#sectorIds + 1] = sector64
        else
          local n = C.GetNumDiscoveredSectorResources(sector64)
          local buf = ffi.new("WareYield[?]", n)
          n = C.GetDiscoveredSectorResources(buf, n, sector64)
          for i = 0, n - 1 do
            if needed[ffi.string(buf[i].ware)] then
              sectorIds[#sectorIds + 1] = sector64
              break
            end
          end
        end
      end
    end
    table.sort(sectorIds, Helper.sortComponentName)
    for i = 1, #sectorIds do
      options[i] = {
        key = tostring(sectorIds[i]),
        value = ConvertStringToLuaID(tostring(sectorIds[i])),
        name = GetComponentData(sectorIds[i], "name"),
      }
    end
  elseif kind == "formationshape" then
    local shapes = {}
    local n = C.GetNumFormationShapes()
    local buf = ffi.new("UIFormationInfo[?]", n)
    n = C.GetFormationShapes(buf, n)
    for i = 0, n - 1 do
      shapes[#shapes + 1] = { shape = ffi.string(buf[i].shape), name = ffi.string(buf[i].name) }
    end
    table.sort(shapes, Helper.sortName)
    for i = 1, #shapes do
      options[i] = { key = shapes[i].shape, value = shapes[i].shape, name = shapes[i].name }
    end
  end
  return options
end

-- Replaces the dialog frame for as long as a value is being picked; every close route leads back to
-- the dialog, so the picker reads as a sub-frame of it even though the map holds only one.
function StandingOrders.showParamPicker()
  local menu = StandingOrders.mapMenu
  local picker = StandingOrders.picker
  if type(menu) ~= "table" or type(menu.closeContextMenu) ~= "function" or type(Helper) ~= "table" or picker == nil then
    StandingOrders.Debug("showParamPicker: map menu instance or picker state is not available")
    return false
  end

  picker.options = StandingOrders.buildPickerOptions(picker.kind, picker.param.inputparams)
  if picker.islist then
    picker.selected = {}
    picker.origSelected = {}
    for _, value in ipairs(picker.param.value or {}) do
      local key = pickerKey(picker.kind, value)
      picker.selected[key] = true
      picker.origSelected[key] = true
    end
  end

  local width = Helper.scaleX(pickerWidth)
  local xoffset = (Helper.viewWidth - width) / 2
  local yoffset = Helper.viewHeight / 2

  menu.closeContextMenu()
  StandingOrders.queueTable = nil

  menu.contextMenuMode = "standing_orders_param_picker"
  menu.contextMenuData = {
    mode = "standing_orders_param_picker",
    width = width,
    xoffset = xoffset,
    yoffset = yoffset,
  }

  menu.contextFrame = Helper.createFrameHandle(menu, {
    x = xoffset - 2 * Helper.borderSize,
    y = yoffset,
    width = width + 2 * Helper.borderSize,
    layer = menu.contextFrameLayer or 2,
    standardButtons = { close = true },
    closeOnUnhandledClick = true,
  })
  local frame = menu.contextFrame
  frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

  local titles = pickerTitles[picker.kind]
  local title = ReadText(1001, picker.islist and titles.list or titles.single)

  local ftable = frame:addTable(3, { tabOrder = 1, x = Helper.borderSize, y = Helper.borderSize, width = width })
  ftable:setColWidth(1, Helper.standardTextHeight)
  ftable:setColWidthPercent(3, 50)

  if picker.islist then
    local titleRow = ftable:addRow(true, { fixed = true })
    titleRow[1]:createCheckBox(function () return #picker.options == StandingOrders.pickerNumSelected() end, { height = Helper.standardTextHeight })
    titleRow[1].handlers.onClick = function (_, checked) return StandingOrders.checkboxPickerToggleAll(checked) end
    titleRow[2]:setColSpan(2):createText(title, Helper.headerRowCenteredProperties)
  else
    local titleRow = ftable:addRow(false, { fixed = true, bgColor = Color["row_background_blue"] })
    titleRow[1]:setColSpan(3):createText(title, Helper.headerRowCenteredProperties)
  end

  if #picker.options == 0 then
    local row = ftable:addRow(false, {  })
    row[1]:setColSpan(3):createText("--- " .. ReadText(1001, 32) .. " ---", { halign = "center" })
  elseif picker.islist then
    for i = 1, #picker.options do
      local option = picker.options[i]
      local row = ftable:addRow(true, {  })
      row[1]:createCheckBox(function () return picker.selected[option.key] or false end, { height = Helper.standardTextHeight })
      row[1].handlers.onClick = function (_, checked) return StandingOrders.checkboxPickerOption(option.key, checked) end
      row[2]:setColSpan(2):createText(option.name)
    end
  else
    for i = 1, #picker.options do
      local option = picker.options[i]
      local row = ftable:addRow(true, {  })
      row[1]:setColSpan(3):createButton({ bgColor = Color["button_background_hidden"], height = Helper.standardTextHeight }):setText(option.name)
      row[1].handlers.onClick = function () return StandingOrders.buttonPickerSetValue(option.value) end
    end
  end

  --- buttons ---
  local buttontable = frame:addTable(2, { tabOrder = 2, x = Helper.borderSize, width = width, reserveScrollBar = false, highlightMode = "off" })
  local buttonRow = buttontable:addRow(true, { fixed = true })
  if picker.islist then
    -- Same gate ego puts on its own confirm: a required list may not be emptied, and an untouched
    -- selection has nothing to write.
    buttonRow[1]:createButton({ active = function ()
      return ((not picker.param.required) or (StandingOrders.pickerNumSelected() > 0)) and StandingOrders.isPickerSelectionChanged()
    end }):setText(ReadText(1001, 14), { halign = "center" })
    buttonRow[1].handlers.onClick = StandingOrders.buttonPickerSetList
  end
  buttonRow[2]:createButton():setText(ReadText(1001, 64), { halign = "center" })
  buttonRow[2].handlers.onClick = StandingOrders.buttonClosePicker
  buttontable:setSelectedRow(buttonRow.index)
  buttontable:setSelectedCol(2)

  --- layout ---
  local buttonHeight = buttontable:getFullHeight()
  local maxListHeight = Helper.viewHeight - 2 * Helper.borderSize - ftable.properties.y - buttonHeight - 2 * Helper.borderSize
  if ftable:getFullHeight() > maxListHeight then
    ftable.properties.maxVisibleHeight = maxListHeight
  end
  buttontable.properties.y = ftable.properties.y + ftable:getVisibleHeight() + Helper.borderSize

  centerFrameVertically(frame)

  frame:display()

  StandingOrders.ensurePaused()
  return true
end

-- Reason a ship would be skipped, or nil. Re-evaluated on every dialog build, since editing a ware
-- param changes what the queue demands of a hold.
function StandingOrders.targetIssue(shipId, transportTypes)
  if StandingOrders.isBlocked(shipId) then
    return ReadText(1972092408, 10324)
  end
  for i = 1, #transportTypes do
    if StandingOrders.getCargoCapacity(shipId, transportTypes[i]) == 0 then
      return ReadText(1972092408, 10125)
    end
  end
  return nil
end

function StandingOrders.cloneOrdersPrepare()
  local valid, errorData = StandingOrders.isValidSourceShip()
  if not valid then
    StandingOrders.showSourceAlert(errorData)
    return false, errorData
  end
  local args = StandingOrders.args or {}
  StandingOrders.sourceId = toUniverseId(args.source)
  StandingOrders.staged = StandingOrders.buildStagedQueue(StandingOrders.sourceId)
  StandingOrders.queueTopRow = nil
  local transportTypes = StandingOrders.stagedTransportTypes()
  local targets = args.targets or {}
  local targetIds = {}
  -- A ship whose queue cannot be cleared still belongs in the list: it is shown greyed out so the
  -- player sees why it is being left alone, rather than silently disappearing.
  StandingOrders.blocked = {}
  for i = 1, #targets do
    local targetId = toUniverseId(targets[i])
    if targetId ~= StandingOrders.sourceId then
      local valid, errorData = StandingOrders.isValidTargetShip(targetId, transportTypes)
      if valid then
        targetIds[#targetIds + 1] = targetId
        if not StandingOrders.canClearOrders(targetId) then
          StandingOrders.blocked[tostring(targetId)] = true
        end
      end
    end
  end
  if #targetIds == 0 then
    StandingOrders.sourceId = 0
    StandingOrders.showTargetAlert()
    return false, { info = "NoValidTargets" }
  end
  StandingOrders.targetIds = targetIds
  StandingOrders.sourceBlocked = not StandingOrders.canClearOrders(StandingOrders.sourceId)
  if StandingOrders.sourceBlocked then
    StandingOrders.applyToSource = false
  end
  return true
end



function StandingOrders.cloneOrdersConfirm()
  local menu = StandingOrders.mapMenu
  if type(menu) ~= "table" or type(menu.closeContextMenu) ~= "function" then
    StandingOrders.Debug("alertMessage: Invalid menu instance")
    return false, "Map menu instance is not available"
  end
  if type(Helper) ~= "table" then
    StandingOrders.Debug("alertMessage: Helper UI utilities are not available")
    return false, "Helper UI utilities are not available"
  end

  local sourceId = StandingOrders.sourceId
  local targetIds = StandingOrders.targetIds

  StandingOrders.refreshStagedCapacities()
  local transportTypes = StandingOrders.stagedTransportTypes()
  local targetIssues = {}
  local anyTargetUsable = false
  for i = 1, #targetIds do
    targetIssues[i] = StandingOrders.targetIssue(targetIds[i], transportTypes)
    anyTargetUsable = anyTargetUsable or (targetIssues[i] == nil)
  end
  local sourceIssue = StandingOrders.targetIssue(sourceId, transportTypes)

  local sourceName = getShipName(sourceId)
  local title = ReadText(1972092408, 10320)
  local targetsTitle = ReadText(1972092408, 10322)

  -- The order block reproduces the Behaviour tab, so it gets that panel's width and column
  -- geometry; the target names ride along in a 13th column.
  local queueWidth = menu.infoTableWidth or Helper.scaleX(700)
  local targetsWidth = Helper.scaleX(300)
  local labelWidth = Helper.scaleX(90)
  local width = queueWidth - 2 * Helper.standardContainerOffset + Helper.borderSize + targetsWidth
  local xoffset = (Helper.viewWidth - width) / 2
  local yoffset = Helper.viewHeight / 2

  menu.closeContextMenu()

  menu.contextMenuMode = "standing_orders_clone_confirm"
  menu.contextMenuData = {
    mode = "standing_orders_clone_confirm",
    width = width,
    xoffset = xoffset,
    yoffset = yoffset,
  }

  local contextLayer = menu.contextFrameLayer or 2

  menu.contextFrame = Helper.createFrameHandle(menu, {
    x = xoffset - 2 * Helper.borderSize,
    y = yoffset,
    width = width + 2 * Helper.borderSize,
    layer = contextLayer,
    standardButtons = { close = true },
    closeOnUnhandledClick = true,
  })
  local frame = menu.contextFrame
  frame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

  --- header ---
  local headertable = frame:addTable(3, { tabOrder = 0, x = Helper.borderSize, y = Helper.borderSize, width = width, reserveScrollBar = false, highlightMode = "off" })
  headertable:setColWidth(1, labelWidth, false)
  headertable:setColWidth(3, targetsWidth, false)

  local headerRow = headertable:addRow(false, { fixed = true })
  headerRow[1]:setColSpan(3):createText(title, Helper.titleTextProperties)
  headertable:addEmptyRow(Helper.standardTextHeight / 2)

  local headerRow = headertable:addRow(false, { fixed = true })
  headerRow[1]:createText(ReadText(1972092408, 10321), Helper.headerRow1Properties)
  headerRow[2]:createText(sourceName, copyAndEnrichTable(Helper.headerRow1Properties, { color = Color["text_player_current"] }))
  headerRow[3]:createText(targetsTitle, Helper.headerRowCenteredProperties)
  headertable:addEmptyRow(Helper.standardTextHeight / 2)

  --- order queue ---
  local ftable = frame:addTable(13, { tabOrder = 1, x = Helper.borderSize, width = width })
  ftable:setColWidth(1, Helper.standardTextHeight)
  ftable:setColWidth(2, Helper.standardTextHeight)
  ftable:setColWidth(3, 2 * Helper.standardTextHeight)
  ftable:setColWidth(4, queueWidth / 3 - 4 * Helper.scaleY(Helper.standardTextHeight) - 3 * Helper.borderSize, false)
  ftable:setColWidth(5, Helper.standardTextHeight)
  ftable:setColWidth(6, Helper.standardTextHeight)
  ftable:setColWidth(7, queueWidth / 3 - 2 * Helper.scaleY(Helper.standardTextHeight) - Helper.borderSize, false)
  ftable:setColWidth(9, Helper.standardTextHeight)
  ftable:setColWidth(10, Helper.standardTextHeight)
  ftable:setColWidth(11, Helper.standardTextHeight)
  ftable:setColWidth(12, Helper.standardTextHeight)
  ftable:setColWidth(13, targetsWidth, false)
  ftable:setDefaultCellProperties("button", { height = Helper.standardTextHeight })
  ftable:setDefaultBackgroundColSpan(1, 12)
  ftable:setDefaultColSpan(5, 3)
  StandingOrders.queueTable = ftable

  -- Order rows and target names are emitted together so the two lists scroll as one.
  local zipper = { next = 1 }
  function zipper.add(rowdata, properties)
    local row = ftable:addRow(rowdata, properties)
    if zipper.next <= #targetIds then
      local issue = targetIssues[zipper.next]
      row[13]:createText(getShipName(targetIds[zipper.next]), {
        color = issue and Color["text_inactive"] or Color["text_player_current"],
        mouseOverText = issue,
      })
      zipper.next = zipper.next + 1
    end
    return row
  end

  local titleRow = ftable:addRow(false, Helper.headerRowProperties)
  titleRow[1]:setColSpan(12):createText(utf8.char(8734) .. " " .. ReadText(1001, 3225) .. " [" .. ReadText(1001, 11270) .. "]", Helper.headerRowCenteredProperties)
  local countRow = ftable:addRow(false, { bgColor = Color["row_background_unselectable"] })
  countRow[1]:setColSpan(12):createText(string.format(ReadText(1001, 11271), #StandingOrders.staged) .. ReadText(1001, 120), { font = Helper.standardFontBold })
  ftable:addEmptyRow(1)

  StandingOrders.addStagedOrderRows(zipper)
  while zipper.next <= #targetIds do
    zipper.add(false, {  })
  end

  if StandingOrders.queueTopRow then
    ftable:setTopRow(StandingOrders.queueTopRow)
  end

  --- buttons ---
  local buttontable = frame:addTable(13, { tabOrder = 2, x = Helper.borderSize, width = width, reserveScrollBar = false, highlightMode = "off" })

  buttontable:addEmptyRow(Helper.standardTextHeight / 2)

  local advancedRow = buttontable:addRow(true, { fixed = true })
  advancedRow[1]:createCheckBox(StandingOrders.showAdvanced, { width = Helper.standardTextHeight })
  advancedRow[1].handlers.onClick = function (_, checked)
    StandingOrders.showAdvanced = checked
    StandingOrders.refreshCloneDialog()
  end
  advancedRow[2]:setColSpan(5):createText(ReadText(1001, 8361))
  advancedRow[7]:createCheckBox(StandingOrders.applyToSource, {
    active = sourceIssue == nil,
    width = Helper.standardTextHeight,
    mouseOverText = sourceIssue,
  })
  advancedRow[7].handlers.onClick = function (_, checked)
    StandingOrders.applyToSource = checked
  end
  advancedRow[8]:setColSpan(6):createText(ReadText(1972092408, 10323), {
    color = sourceIssue and Color["text_inactive"] or nil,
    mouseOverText = sourceIssue,
  })

  buttontable:addEmptyRow(Helper.standardTextHeight / 2)

  local buttonRow = buttontable:addRow(true, { fixed = true })
  buttonRow[1]:setColSpan(2):createButton():setText(ReadText(1972092408, 10201), { halign = "center" })
  buttonRow[1].handlers.onClick = function ()
    StandingOrders.clearSource()
    menu.closeContextMenu("back")
  end
  -- Re-evaluated by Helper, since the apply-to-source checkbox does not rebuild the dialog.
  local canApply = function ()
    return anyTargetUsable or (StandingOrders.applyToSource and (sourceIssue == nil))
  end
  buttonRow[10]:setColSpan(2):createButton({ active = canApply }):setText(ReadText(1001, 2821), { halign = "center" })
  buttonRow[10].handlers.onClick = function ()
    local valid, errorData = StandingOrders.cloneOrdersExecute()
    menu.closeContextMenu("back")
    if not valid then
      StandingOrders.showSourceAlert(errorData)
    end
  end
  buttonRow[12]:setColSpan(2):createButton():setText(ReadText(1001, 64), { halign = "center" })
  buttonRow[12].handlers.onClick = function ()
    StandingOrders.cloneOrdersCancel()
    menu.closeContextMenu("back")
  end
  buttontable:setSelectedRow(buttonRow.index)
  buttontable:setSelectedCol(12)

  --- layout ---
  ftable.properties.y = headertable.properties.y + headertable:getFullHeight() + Helper.borderSize
  local buttonHeight = buttontable:getFullHeight()
  local maxQueueHeight = Helper.viewHeight - 2 * Helper.borderSize - ftable.properties.y - buttonHeight - 2 * Helper.borderSize
  if ftable:getFullHeight() > maxQueueHeight then
    ftable.properties.maxVisibleHeight = maxQueueHeight
  end
  buttontable.properties.y = ftable.properties.y + ftable:getVisibleHeight() + Helper.borderSize

  centerFrameVertically(frame)

  frame:display()

  StandingOrders.ensurePaused()
end

function StandingOrders.cloneOrdersExecute()
  -- The confirmation dialog stays open until the player acts; source and targets can die in between.
  local valid, errorData = StandingOrders.checkShip(StandingOrders.sourceId)
  if not valid then
    StandingOrders.Debug("source is no longer valid at execution time - aborting")
    StandingOrders.cloneOrdersReset()
    StandingOrders.reportError(errorData)
    return false, errorData
  end
  local sourceId = StandingOrders.sourceId
  local staged = StandingOrders.staged
  local transportTypes = StandingOrders.stagedTransportTypes()

  -- Everything applied comes from the staged snapshot, so wiping the source's own queue last is
  -- safe; it is appended rather than special-cased.
  local targets = {}
  for i = 1, #StandingOrders.targetIds do
    targets[#targets + 1] = StandingOrders.targetIds[i]
  end
  if StandingOrders.applyToSource and not StandingOrders.sourceBlocked then
    targets[#targets + 1] = sourceId
  end
  StandingOrders.Debug("Executing clone orders from source " .. getShipName(sourceId) .. " to " .. tostring(#targets) .. " ships")

  -- Capacities are read once, before any queue is touched.
  StandingOrders.refreshStagedCapacities()

  local processedOrders = 0
  for i = 1, #targets do
    local targetId = targets[i]
    StandingOrders.Trace("Cloning orders to target " .. getShipName(targetId))
    if StandingOrders.isBlocked(targetId) then
      StandingOrders.Debug("skipping target " .. getShipName(targetId) .. " - order queue cannot be cleared")
    elseif not StandingOrders.checkShip(targetId, transportTypes) then
      StandingOrders.Debug("skipping target " .. getShipName(targetId) .. " - no longer valid")
    elseif not C.RemoveAllOrders(targetId) then
      StandingOrders.Error("failed to clear target order queue for " .. getShipName(targetId))
    else
      C.CreateOrder(targetId, "Wait", true)
      C.EnablePlannedDefaultOrder(targetId, false)
      C.SetOrderLoop(targetId, 0, false)
      for j = 1, #staged do
        local order = staged[j]
        local sourceCapacity = order.sourceCapacity
        local newOrderIdx = C.CreateOrder(targetId, order.orderdef, false)
        if newOrderIdx and newOrderIdx > 0 then
          local targetCapacity = order.transportType and StandingOrders.getCargoCapacity(targetId, order.transportType) or nil
          for paramIdx = 1, #order.params do
            local param = order.params[paramIdx]
            if param.type ~= "internal" and param.value ~= nil then
              if param.type == "list" then
                for l = 1, #param.value do
                  SetOrderParam(targetId, newOrderIdx, paramIdx, nil, param.value[l])
                end
              else
                local value = param.value
                if param.type == "money" then
                  -- GetOrderParams returns display scale, SetOrderParam expects x100
                  value = value * 100
                elseif param.type == "position" then
                  value = { ConvertStringToLuaID(tostring(value[1])), { value[2].x, value[2].y, value[2].z } }
                elseif isCargoBoundParam(param, sourceCapacity) then
                  value = (sourceCapacity > 0) and math.floor(value / sourceCapacity * targetCapacity) or 0
                end
                SetOrderParam(targetId, newOrderIdx, paramIdx, nil, value)
              end
            end
          end
          StandingOrders.Trace(" Created order " .. tostring(order.orderdef) .. " on target " .. getShipName(targetId) .. " at index " .. tostring(newOrderIdx))
          C.EnableOrder(targetId, newOrderIdx)
          processedOrders = processedOrders + 1
        else
          StandingOrders.Error(" Failed to create order " .. tostring(order.orderdef) .. " on target " .. getShipName(targetId))
        end
      end
    end
  end
  StandingOrders.cloneOrdersReset()
  if processedOrders == 0 then
    StandingOrders.reportError({ info = "NoOrdersCloned" })
  else
    StandingOrders.reportSuccess({ info = "OrdersCloned", details = string.format("%d orders cloned to %d ships", processedOrders, #targets) })
  end
  return true
end

function StandingOrders.cloneOrdersCancel()
  StandingOrders.cloneOrdersReset()
  StandingOrders.reportSuccess({result = "cancelled"})
end

function StandingOrders.clearSource()
  StandingOrders.cloneOrdersReset()
  StandingOrders.args.command = "unmark_source"
  StandingOrders.MarkSourceOnMap()
end

function StandingOrders.cloneOrdersReset()
  StandingOrders.sourceId = 0
  StandingOrders.targetIds = {}
  StandingOrders.staged = {}
  StandingOrders.picker = nil
  StandingOrders.picking = nil
  StandingOrders.queueTable = nil
  StandingOrders.queueTopRow = nil
  StandingOrders.applyToSource = false
  StandingOrders.blocked = {}
  StandingOrders.sourceBlocked = false
end

function StandingOrders.ProcessRequest(_, _)
  if StandingOrders.mapMenu and StandingOrders.mapMenu.holomap and (StandingOrders.mapMenu.holomap ~= 0) then
    -- A request arriving mid-pick would leave the map in a mode pointing at a queue we are about to
    -- replace, so end the pick first.
    if StandingOrders.picking then
      StandingOrders.picking = nil
      StandingOrders.mapMenu.resetOrderParamMode()
      StandingOrders.releasePause()
    end
    if not StandingOrders.getArgs() then
      StandingOrders.Debug("ProcessRequest invoked without args or invalid args")
      StandingOrders.reportError({info ="missing_args"})
      return
    end
    StandingOrders.Debug("ProcessRequest received command: " .. tostring(StandingOrders.args.command))
    if StandingOrders.args.command == "mark_source" then
      local valid, errorData = StandingOrders.isValidSourceShip(StandingOrders.args.source)
      if valid then
        StandingOrders.MarkSourceOnMap()
      else
        StandingOrders.showSourceAlert(errorData)
        StandingOrders.reportError(errorData)
      end
    elseif StandingOrders.args.command == "unmark_source" then
      StandingOrders.MarkSourceOnMap()
    elseif StandingOrders.args.command == "clone_orders" then
      local valid, errorData = StandingOrders.cloneOrdersPrepare()
      if valid then
        StandingOrders.cloneOrdersConfirm()
      else
        StandingOrders.reportError(errorData)
      end
    else
      StandingOrders.Debug("ProcessRequest received unknown command: " .. tostring(StandingOrders.args.command))
      StandingOrders.reportError({ info = "UnknownCommand" })
    end
  else
    StandingOrders.Debug("ProcessRequest invoked but no MapMenu or Holomap available")
    StandingOrders.reportError({ info = "NoMap" })
  end
end

local ownContextModes = {
  standing_orders_alert = true,
  standing_orders_clone_confirm = true,
  standing_orders_param_picker = true,
}

-- onTableMouseOver clears menu.picking; onTableMouseOut only restores it if the cursor leaves the
-- same table, which never happens when our frame is destroyed under it. Ego repairs that in
-- closeContextMenu, but only for a hardcoded list of its own contextMenuModes. Wrap the one
-- funnel all close routes share -- our buttons, the frame's X, and closeOnUnhandledClick.
local function hookCloseContextMenu(menu)
  if type(menu) ~= "table" or type(menu.closeContextMenu) ~= "function" then
    StandingOrders.Debug("hookCloseContextMenu: no usable map menu")
    return
  end
  -- Kept on the menu itself, which outlives a reload of this module, so the wrapper cannot stack.
  if menu.standingOrdersCloseContextMenu ~= nil then
    return
  end
  menu.standingOrdersCloseContextMenu = menu.closeContextMenu
  menu.closeContextMenu = function (dueToClose, keepmenu)
    local mode = menu.contextMenuMode
    local result = menu.standingOrdersCloseContextMenu(dueToClose, keepmenu)
    if ownContextModes[mode] then
      if menu.holomap and (menu.holomap ~= 0) then
        menu.picking = true
      end
      menu.currentMouseOverTable = nil
    end
    -- A pick takes the dialog down for the map's sake, which is no more the dialog going away than
    -- a rebuild is; the pause has to survive it too.
    if not StandingOrders.rebuilding and not StandingOrders.picking then
      if mode == "standing_orders_param_picker" then
        -- The picker has no parent frame to fall back to, so every close route -- its Cancel, the
        -- frame's X, closeOnUnhandledClick -- has to put the dialog back itself.
        StandingOrders.picker = nil
        StandingOrders.refreshCloneDialog()
      elseif mode == "standing_orders_clone_confirm" then
        StandingOrders.releasePause()
      end
    end
    return result
  end
end

-- The map menu's cleanup nils contextMenuMode without going through closeContextMenu, so closing
-- the map with the dialog open would otherwise leave the game paused for good -- and a picker left
-- staged here would be rendered again by the next refresh of an unrelated dialog.
local function hookCleanup(menu)
  if type(menu) ~= "table" or type(menu.cleanup) ~= "function" then
    StandingOrders.Debug("hookCleanup: no usable map menu")
    return
  end
  if menu.standingOrdersCleanup ~= nil then
    return
  end
  menu.standingOrdersCleanup = menu.cleanup
  menu.cleanup = function (...)
    StandingOrders.releasePause()
    StandingOrders.picker = nil
    if StandingOrders.picking then
      -- cleanup nils menu.mode without going through resetOrderParamMode, which is what would
      -- normally drop the target cursor.
      StandingOrders.picking = nil
      menu.removeMouseCursorOverride(3)
    end
    return menu.standingOrdersCleanup(...)
  end
end

-- Picked, right-clicked or escaped, every way out of an orderparam mode funnels through
-- resetOrderParamMode, and it is the only signal that the map is finished with us. Vanilla ends a
-- pick by redrawing the info panel it was started from; ours has to put the dialog back.
local function hookResetOrderParamMode(menu)
  if type(menu) ~= "table" or type(menu.resetOrderParamMode) ~= "function" then
    StandingOrders.Debug("hookResetOrderParamMode: no usable map menu")
    return
  end
  if menu.standingOrdersResetOrderParamMode ~= nil then
    return
  end
  menu.standingOrdersResetOrderParamMode = menu.resetOrderParamMode
  menu.resetOrderParamMode = function (...)
    local waspicking = StandingOrders.picking ~= nil
    local result = menu.standingOrdersResetOrderParamMode(...)
    if waspicking then
      StandingOrders.picking = nil
      StandingOrders.refreshCloneDialog()
    end
    return result
  end
end

function StandingOrders.Init()
  getPlayerId()
  ---@diagnostic disable-next-line: undefined-global
  RegisterEvent("StandingOrders.Request", StandingOrders.ProcessRequest)
  ---@diagnostic disable-next-line: undefined-global
  RegisterEvent("StandingOrders.SetDebugLevel", StandingOrders.SetDebugLevel)
  StandingOrders.ReadDebugLevel()
  AddUITriggeredEvent("StandingOrders", "Reloaded")
  StandingOrders.mapMenu = Lib.Get_Egosoft_Menu("MapMenu")
  StandingOrders.Trace("MapMenu is " .. tostring(StandingOrders.mapMenu))
  hookCloseContextMenu(StandingOrders.mapMenu)
  hookCleanup(StandingOrders.mapMenu)
  hookResetOrderParamMode(StandingOrders.mapMenu)
  StandingOrders.loopOrdersSkillLimit = C.GetOrderLoopSkillLimit() * 3
end

Register_Require_With_Init("extensions.standing_orders.ui.standing_orders", StandingOrders, StandingOrders.Init)

return StandingOrders
