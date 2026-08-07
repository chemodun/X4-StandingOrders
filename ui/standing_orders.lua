local ffi = require("ffi")
local C = ffi.C

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

	UniverseID GetPlayerID(void);

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
]]

local StandingOrders = {
  args = {},
  playerId = 0,
  mapMenu = {},
  orderDefs = {},
  loopOrdersSkillLimit = 0,
  sourceId = 0,
  targetIds = {},
}


local Lib = require("extensions.sn_mod_support_apis.ui.Library")

local function debugTrace(message)
  local text = "StandingOrders: " .. message
  if type(DebugError) == "function" then
    DebugError(text)
  end
end

local function getPlayerId()
  local current = C.GetPlayerID()
  if current == nil or current == 0 then
    return
  end

  local converted = ConvertStringTo64Bit(tostring(current))
  if converted ~= 0 and converted ~= StandingOrders.playerId then
    debugTrace("updating player_id to " .. tostring(converted))
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
      debugTrace("order definition " .. tostring(orderDef) .. " could not be resolved")
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
  debugTrace("recordResult called for command ".. tostring(data and data.command) .. " with result " .. tostring(data and data.result))
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

  local message = "StandingOrders error"
  if data.info then
    message = message .. ": " .. tostring(data.info)
  end
  if data.detail then
    message = message .. " (" .. tostring(data.detail) .. ")"
  end

  DebugError(message)
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

function StandingOrders.collectSourceTransportTypes(sourceId, orders)
  local seen = {}
  local list = {}
  for i = 1, #orders do
    local transportType = findWareTransportType(GetOrderParams(sourceId, orders[i].idx))
    if transportType ~= nil and seen[transportType] == nil then
      seen[transportType] = true
      list[#list + 1] = transportType
    end
  end
  return list
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
    debugTrace("getArgs unable to resolve player id")
  else
    local list = GetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersRequest")
    if type(list) == "table" then
      debugTrace("getArgs retrieved " .. tostring(#list) .. " entries from blackboard")
      StandingOrders.args = list[#list]
      SetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersRequest", nil)
      return true
    elseif list ~= nil then
      debugTrace("getArgs received non-table payload of type " .. type(list))
    else
      debugTrace("getArgs found no blackboard entries for player " .. tostring(StandingOrders.playerId))
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

  debugTrace("MapMenu is " .. tostring(StandingOrders.mapMenu) .. " for source " .. source)
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
    debugTrace("alertMessage: Invalid menu instance")
    return false, "Map menu instance is not available"
  end
  if type(Helper) ~= "table" then
    debugTrace("alertMessage: Helper UI utilities are not available")
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


-- Formatting is delegated to the map menu's own getParamValue, which already covers every
-- param type the engine emits. Objects it names can vanish mid-dialog, hence the pcall.
local function formatParamValue(param, sourceCapacity)
  local menu = StandingOrders.mapMenu
  local function format(valueType, value)
    local ok, result = pcall(menu.getParamValue, valueType, value, param.inputparams)
    if not ok or result == nil then
      return tostring(value)
    end
    local flattened = tostring(result):gsub("\n", " / ")
    return flattened
  end

  if param.type == "list" then
    local innerType = param.inputparams and param.inputparams.type
    local items = {}
    for i = 1, #(param.value or {}) do
      items[#items + 1] = format(innerType, param.value[i])
    end
    if #items == 0 then
      return "-"
    end
    return table.concat(items, ", ")
  end

  local text = format(param.type, param.value)
  if isCargoBoundParam(param, sourceCapacity) and sourceCapacity > 0 then
    text = string.format("%s (%.2f%%)", text, param.value * 100 / sourceCapacity)
  end
  return text
end

-- Flattens the queue into renderable lines: a header per order, then one row per settable param.
function StandingOrders.buildPreviewLines(sourceId)
  local lines = {}
  local orders = StandingOrders.getStandingOrders(sourceId)
  for i = 1, #orders do
    local order = orders[i]
    local def = getOrderDef(order.order)
    local header = def.name
    if def.icon ~= "" then
      header = "\27[" .. def.icon .. "] " .. header
    end
    lines[#lines + 1] = { kind = "order", text = header }

    local orderParams = GetOrderParams(sourceId, order.idx) or {}
    local transportType = findWareTransportType(orderParams)
    local sourceCapacity = transportType and StandingOrders.getCargoCapacity(sourceId, transportType) or nil
    for paramIdx = 1, #orderParams do
      local param = orderParams[paramIdx]
      -- Vanilla's order queue hides advanced params unless the panel is in advanced mode. This
      -- only filters the preview; cloneOrdersExecute still copies them.
      if param.type ~= "internal" and param.value ~= nil and not param.advanced then
        local label = param.text
        if label == nil or label == "" then
          label = tostring(param.name)
        end
        lines[#lines + 1] = { kind = "param", label = label, value = formatParamValue(param, sourceCapacity) }
      end
    end
  end
  return lines
end

function StandingOrders.cloneOrdersPrepare()
  local valid, errorData = StandingOrders.isValidSourceShip()
  if not valid then
    StandingOrders.showSourceAlert(errorData)
    return false, errorData
  end
  local args = StandingOrders.args or {}
  StandingOrders.sourceId = toUniverseId(args.source)
  local sourceOrders = StandingOrders.getStandingOrders(StandingOrders.sourceId)
  local transportTypes = StandingOrders.collectSourceTransportTypes(StandingOrders.sourceId, sourceOrders)
  local targets = args.targets or {}
  local targetIds = {}
  for i = 1, #targets do
    local targetId = toUniverseId(targets[i])
    if targetId ~= StandingOrders.sourceId then
      local valid, errorData = StandingOrders.isValidTargetShip(targetId, transportTypes)
      if valid then
        targetIds[#targetIds + 1] = targetId
      end
    end
  end
  if #targetIds == 0 then
    StandingOrders.sourceId = 0
    StandingOrders.showTargetAlert()
    return false, { info = "NoValidTargets" }
  end
  StandingOrders.targetIds = targetIds
  return true
end



function StandingOrders.cloneOrdersConfirm()
  local menu = StandingOrders.mapMenu
  if type(menu) ~= "table" or type(menu.closeContextMenu) ~= "function" then
    debugTrace("alertMessage: Invalid menu instance")
    return false, "Map menu instance is not available"
  end
  if type(Helper) ~= "table" then
    debugTrace("alertMessage: Helper UI utilities are not available")
    return false, "Helper UI utilities are not available"
  end

  local sourceId = StandingOrders.sourceId
  local targetIds = StandingOrders.targetIds

  local sourceName = getShipName(sourceId)
  local title = ReadText(1972092408, 10320)
  local targetsTitle = ReadText(1972092408, 10322)

  local width = Helper.scaleX(910)
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

  local ftable = frame:addTable(13, { tabOrder = 1, x = Helper.borderSize, y = Helper.borderSize, width = width, reserveScrollBar = false, highlightMode = "off" })

  local headerRow = ftable:addRow(false, { fixed = true })
  headerRow[1]:setColSpan(13):createText(title, Helper.titleTextProperties)
  ftable:addEmptyRow(Helper.standardTextHeight / 2)
  local headerRow = ftable:addRow(false, { fixed = true })
  headerRow[1]:createText(ReadText(1972092408, 10321), Helper.headerRow1Properties)
  local sourceNameProperties = copyAndEnrichTable(Helper.headerRowCenteredProperties, {color = Color["text_player_current"]})
  headerRow[2]:setColSpan(7):createText(sourceName, sourceNameProperties)
  headerRow[9]:setColSpan(5):createText(targetsTitle, Helper.headerRowCenteredProperties)
  ftable:addEmptyRow(Helper.standardTextHeight / 2)


  local headerRow = ftable:addRow(false, { fixed = true })
  headerRow[1]:setColSpan(8):createText(ReadText(1001, 3225), Helper.headerRowCenteredProperties) -- Order Queue

  local tableHeaderRow = ftable:addRow(false, { fixed = true })
  tableHeaderRow[1]:setColSpan(8):createText(ReadText(1001, 7802), Helper.headerRow1Properties) -- Orders
  tableHeaderRow[9]:setColSpan(5):createText(ReadText(1001, 2809), Helper.headerRow1Properties) -- Name

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local lines = StandingOrders.buildPreviewLines(sourceId)
  local lineCount = math.max(#lines, #targetIds)
  for i = 1, lineCount do
    local row = ftable:addRow(false)
    local line = lines[i]
    if line == nil then
      row[1]:setColSpan(8):createText("", {halign = "left"})
    elseif line.kind == "order" then
      row[1]:setColSpan(8):createText(line.text, copyAndEnrichTable(Helper.headerRow1Properties, {color = Color["text_player_current"]}))
    else
      row[1]:setColSpan(3):createText("  " .. line.label .. ReadText(1001, 120), {halign = "left"})
      row[4]:setColSpan(5):createText(line.value, {halign = "left"})
    end
    if i <= #targetIds then
      local targetName = getShipName(targetIds[i])
      row[9]:setColSpan(5):createText(tostring(targetName), {halign = "left", color = Color["text_player_current"]})
    else
      row[9]:setColSpan(5):createText("", {halign = "center"})
    end
  end

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local buttonRow = ftable:addRow(true, { fixed = true })
  buttonRow[10]:setColSpan(2):createButton():setText(ReadText(1001, 2821), { halign = "center" })
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
  buttonRow[1]:setColSpan(2):createButton():setText(ReadText(1972092408, 10201), { halign = "center" })
  buttonRow[1].handlers.onClick = function ()
    StandingOrders.clearSource()
    menu.closeContextMenu("back")
  end
  ftable:setSelectedCol(12)

  centerFrameVertically(frame)

  frame:display()
end

function StandingOrders.cloneOrdersExecute()
  -- The confirmation dialog stays open until the player acts; source and targets can die in between.
  local valid, errorData = StandingOrders.checkShip(StandingOrders.sourceId)
  if not valid then
    debugTrace("source is no longer valid at execution time - aborting")
    StandingOrders.cloneOrdersReset()
    StandingOrders.reportError(errorData)
    return false, errorData
  end
  local sourceId = StandingOrders.sourceId
  debugTrace("Executing clone orders from source " .. getShipName(sourceId) .. " to " .. tostring(#StandingOrders.targetIds) .. " targets")
  local sourceOrders = StandingOrders.getStandingOrders(sourceId)
  local targets = StandingOrders.targetIds
  local transportTypes = StandingOrders.collectSourceTransportTypes(sourceId, sourceOrders)

  -- Snapshot the source up front: clearing a target's queue must never be able to invalidate
  -- what we still have to read from the source.
  local snapshot = {}
  for j = 1, #sourceOrders do
    local order = sourceOrders[j]
    local orderParams = GetOrderParams(sourceId, order.idx) or {}
    if #orderParams > 0 then
      local transportType = findWareTransportType(orderParams)
      snapshot[#snapshot + 1] = {
        order = order.order,
        params = orderParams,
        transportType = transportType,
        sourceCapacity = transportType and StandingOrders.getCargoCapacity(sourceId, transportType) or nil,
      }
    end
  end

  local processedOrders = 0
  for i = 1, #targets do
    local targetId = targets[i]
    debugTrace("Cloning orders to target " .. getShipName(targetId))
    if targetId == sourceId then
      debugTrace("skipping target " .. getShipName(targetId) .. " - it is the source ship")
    elseif not StandingOrders.checkShip(targetId, transportTypes) then
      debugTrace("skipping target " .. getShipName(targetId) .. " - no longer valid")
    elseif not C.RemoveAllOrders(targetId) then
      debugTrace("failed to clear target order queue for " .. getShipName(targetId))
    else
      C.CreateOrder(targetId, "Wait", true)
      C.EnablePlannedDefaultOrder(targetId, false)
      C.SetOrderLoop(targetId, 0, false)
      for j = 1, #snapshot do
        local order = snapshot[j]
        local sourceCapacity = order.sourceCapacity
        local newOrderIdx = C.CreateOrder(targetId, order.order, false)
        if newOrderIdx and newOrderIdx > 0 then
          local targetCapacity = order.transportType and StandingOrders.getCargoCapacity(targetId, order.transportType) or nil
          for paramIdx = 1, #order.params do
            local param = order.params[paramIdx]
            if param.type ~= "internal" then
              if param.type == "list" then
                for l = 1, #(param.value or {}) do
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
          debugTrace(" Created order " .. tostring(order.order) .. " on target " .. getShipName(targetId) .. " at index " .. tostring(newOrderIdx))
          C.EnableOrder(targetId, newOrderIdx)
          processedOrders = processedOrders + 1
        else
          debugTrace(" Failed to create order " .. tostring(order.order) .. " on target " .. getShipName(targetId))
        end
      end
    end
  end
  StandingOrders.cloneOrdersReset()
  if processedOrders == 0 then
    StandingOrders.reportError({ info = "NoOrdersCloned" })
  else
    StandingOrders.reportSuccess({ info = "OrdersCloned", details = string.format("%d orders cloned to %d targets", processedOrders, #targets) })
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
end

function StandingOrders.ProcessRequest(_, _)
  if StandingOrders.mapMenu and StandingOrders.mapMenu.holomap and (StandingOrders.mapMenu.holomap ~= 0) then
    if not StandingOrders.getArgs() then
      debugTrace("ProcessRequest invoked without args or invalid args")
      StandingOrders.reportError({info ="missing_args"})
      return
    end
    debugTrace("ProcessRequest received command: " .. tostring(StandingOrders.args.command))
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
      debugTrace("ProcessRequest received unknown command: " .. tostring(StandingOrders.args.command))
      StandingOrders.reportError({ info = "UnknownCommand" })
    end
  else
    debugTrace("ProcessRequest invoked but no MapMenu or Holomap available")
    StandingOrders.reportError({ info = "NoMap" })
  end
end

function StandingOrders.Init()
  getPlayerId()
  ---@diagnostic disable-next-line: undefined-global
  RegisterEvent("StandingOrders.Request", StandingOrders.ProcessRequest)
  AddUITriggeredEvent("StandingOrders", "Reloaded")
  StandingOrders.mapMenu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(StandingOrders.mapMenu))
  StandingOrders.loopOrdersSkillLimit = C.GetOrderLoopSkillLimit() * 3
end

Register_Require_With_Init("extensions.standing_orders.ui.standing_orders", StandingOrders, StandingOrders.Init)

return StandingOrders
