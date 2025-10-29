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
	bool IsComponentClass(UniverseID componentid, const char* classname);
	bool IsComponentOperational(UniverseID componentid);
	bool IsComponentWrecked(UniverseID componentid);
	uint32_t GetNumCargoTransportTypes(UniverseID containerid, bool merge);
	uint32_t GetCargoTransportTypes(StorageInfo* result, uint32_t resultlen, UniverseID containerid, bool merge, bool aftertradeorders);
	size_t GetOrderQueueFirstLoopIdx(UniverseID controllableid, bool* isvalid);
  uint32_t GetOrders(Order* result, uint32_t resultlen, UniverseID controllableid);
	uint32_t CreateOrder(UniverseID controllableid, const char* orderid, bool default);
	bool EnableOrder(UniverseID controllableid, size_t idx);
]]

local StandingOrders = {
  args = {},
  playerId = 0,
  mapMenu = {},
  validOrders = {
    SingleBuy  = "",
    SingleSell = "",
  },
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

function StandingOrders.checkShip(shipId)
  local shipId = toUniverseId(shipId)
  if shipId == 0 then
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
  if StandingOrders.getCargoCapacity(shipId) == 0 then
    return false, { info = "NoCargoCapacity" }
  end
  return true
end

function StandingOrders.getCargoCapacity(shipId)
  local menu = StandingOrders.mapMenu
  local shipId = toUniverseId(shipId)
  local numStorages = C.GetNumCargoTransportTypes(shipId, true)
  local buf = ffi.new("StorageInfo[?]", numStorages)
  local count = C.GetCargoTransportTypes(buf, numStorages, shipId, true, false)
  local capacity = 0
  for i = 0, count - 1 do
    local tags = menu.getTransportTagsFromString(ffi.string(buf[i].transport))
    if tags.container == true then
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
  for _, order in ipairs(orders) do
    if StandingOrders.validOrders[order.order] == nil then
      return false, { info = "InvalidStandingOrder", detail = "order=" .. tostring(order.order) }
    end
  end
  return true
end

function StandingOrders.isValidTargetShip(target)
  local targetId = toUniverseId(target)
  local valid, errorData = StandingOrders.checkShip(targetId)
  if not valid then
    return false, errorData
  end
  local loopSkill = C.GetOrderLoopSkillLimit() * 3;
  local aiPilot = GetComponentData(ConvertStringToLuaID(tostring(targetId)), "assignedaipilot")
	local aiPilotSkill = aiPilot and math.floor(C.GetEntityCombinedSkill(ConvertIDTo64Bit(aiPilot), nil, "aipilot")) or -1
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

  local sourceName = GetComponentData(ConvertStringToLuaID(tostring(sourceId)), "name")
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
    elseif errorData.info == "InvalidStandingOrder" then
      details = ReadText(1972092408, 10133)
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

  local onClose = options.onClose

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

  local warningProperties = Helper.titleTextProperties
  warningProperties.color = Color["text_warning"]
  local headerRow = ftable:addRow(false, { fixed = true })
  headerRow[1]:setColSpan(5):createText(title, warningProperties)

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local messageRow = ftable:addRow(false, { fixed = true })
  messageRow[1]:setColSpan(5):createText(message, {
    halign = "center",
    valign = "top",
    wordwrap = true,
    color = Color["text_normal"],
    fontname = Helper.standardFont,
    fontsize = Helper.standardFontSize,
  })

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local buttonRow = ftable:addRow(true, { fixed = true })
  buttonRow[3]:createButton():setText(okLabel, { halign = "center" })
  buttonRow[3].handlers.onClick = function ()
    local shouldClose = true
    if type(onClose) == "function" then
      shouldClose = onClose(menu, sourceId) ~= false
    end
    if shouldClose then
      menu.closeContextMenu("back")
    end
  end
  ftable:setSelectedCol(3)

  frame.properties.height = math.min(Helper.viewHeight - frame.properties.y, frame:getUsedHeight() + Helper.borderSize)

  frame:display()

  return true
end

function StandingOrders.showTargetAlert()
  local options = {}
  options.title = ReadText(1972092408, 10310)
  options.message = ReadText(1972092408, 10311)
  StandingOrders.alertMessage(options)
end


function StandingOrders.cloneOrdersPrepare()
  local valid, errorData = StandingOrders.isValidSourceShip()
  if not valid then
    StandingOrders.showSourceAlert(errorData)
    return false, errorData
  end
  local args = StandingOrders.args or {}
  StandingOrders.sourceId = toUniverseId(args.source)
  local targets = args.targets or {}
  local targetIds = {}
  for i = 1, #targets do
    local targetId = toUniverseId(targets[i])
    local valid, errorData = StandingOrders.isValidTargetShip(targetId)
    if valid then
      targetIds[#targetIds + 1] = targetId
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

  local sourceName = GetComponentData(ConvertStringToLuaID(tostring(sourceId)), "name")
  local title = ReadText(1972092408, 10320)
  local sourceTitle = string.format(ReadText(1972092408, 10321), sourceName)
  local targetsTitle = ReadText(1972092408, 10322)

  local width = Helper.scaleX(800)
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

  local ftable = frame:addTable(12, { tabOrder = 1, x = Helper.borderSize, y = Helper.borderSize, width = width, reserveScrollBar = false, highlightMode = "off" })

  local headerRow = ftable:addRow(false, { fixed = true })
  local titleProperties = copyAndEnrichTable(Helper.titleTextProperties, {color = Color["text_positive"]})
  headerRow[1]:setColSpan(12):createText(title, titleProperties)
  ftable:addEmptyRow(Helper.standardTextHeight / 2)
  local headerRow = ftable:addRow(false, { fixed = true })
  local sourceTitleProperties = copyAndEnrichTable(Helper.headerRowCenteredProperties, {color = Color["text_player"]})
  headerRow[1]:setColSpan(8):createText(sourceTitle, sourceTitleProperties)
  local targetsTitleProperties = copyAndEnrichTable(Helper.headerRowCenteredProperties, {color = Color["text_player_current"]})
  headerRow[9]:setColSpan(4):createText(targetsTitle, targetsTitleProperties)
  ftable:addEmptyRow(Helper.standardTextHeight / 2)


  local headerRow = ftable:addRow(false, { fixed = true })
  headerRow[1]:setColSpan(8):createText(ReadText(1001, 3225), Helper.headerRowCenteredProperties) -- Order Queue

  local tableHeaderRow = ftable:addRow(false, { fixed = true })
  tableHeaderRow[1]:createText(ReadText(1001, 7802), Helper.headerRowCenteredProperties) -- Orders
  tableHeaderRow[2]:setColSpan(2):createText(ReadText(1001, 45), Helper.headerRowCenteredProperties) -- Ware
  tableHeaderRow[4]:createText(ReadText(1001, 1202), Helper.headerRowCenteredProperties) -- Amount
  tableHeaderRow[5]:createText(ReadText(1001, 2808), Helper.headerRowCenteredProperties) -- Price
  tableHeaderRow[6]:setColSpan(3):createText(ReadText(1041, 10049), Helper.headerRowCenteredProperties) -- Location
  tableHeaderRow[9]:setColSpan(4):createText(ReadText(1001, 2809), Helper.headerRowCenteredProperties) -- Name

  ftable:addEmptyRow(Helper.standardTextHeight / 2)

  local orders = StandingOrders.getStandingOrders(sourceId)

  local lineCount = math.max(#orders, #targetIds)
  for i = 1, lineCount do
    local row = ftable:addRow(false)
    if i <= #orders then
      local order = orders[i]
      local orderparams = GetOrderParams(sourceId, order.idx)
      row[1]:createText(StandingOrders.validOrders[order.order], {halign = "left"})
      row[2]:setColSpan(2):createText(GetWareData(orderparams[1].value, "name"), {halign = "left"})
      row[4]:createText(math.floor(orderparams[5].value), {halign = "right"})
      row[5]:createText(math.floor(orderparams[7].value), {halign = "right"})
      local locations = orderparams[4].value
      if type(locations) == "table" and #locations >= 1 then
        local locId = toUniverseId(locations[1])
        local locName = GetComponentData(ConvertStringToLuaID(tostring(locId)), "name")
        if (#locations > 1) then
          locName = locName .. ", ..."
        end
        row[6]:setColSpan(3):createText(locName, {halign = "center"})
      else
        row[6]:setColSpan(3):createText("-", {halign = "center"})
      end
    else
      row[1]:setColSpan(8):createText("", {halign = "left"})
    end
    if i <= #targetIds then
      local targetName = GetComponentData(ConvertStringToLuaID(tostring(targetIds[i])), "name")
      row[9]:setColSpan(4):createText(tostring(targetName), {halign = "left"})
    else
      row[9]:setColSpan(4):createText("", {halign = "center"})
    end
  end


  local buttonRow = ftable:addRow(true, { fixed = true })
  buttonRow[9]:setColSpan(2):createButton():setText(ReadText(1001, 2821), { halign = "center" })
  buttonRow[9].handlers.onClick = function ()
    StandingOrders.cloneOrdersExecute()
    menu.closeContextMenu("back")
  end
  buttonRow[10].handlers.onClick = function ()
    StandingOrders.cloneOrdersExecute()
    menu.closeContextMenu("back")
  end
  buttonRow[11]:setColSpan(2):createButton():setText(ReadText(1001, 64), { halign = "center" })
  buttonRow[11].handlers.onClick = function ()
    StandingOrders.cloneOrdersCancel()
    menu.closeContextMenu("back")
  end
  buttonRow[12].handlers.onClick = function ()
    StandingOrders.cloneOrdersCancel()
    menu.closeContextMenu("back")
  end
  -- ftable:setSelectedCol(3)

  frame.properties.height = math.min(Helper.viewHeight - frame.properties.y, frame:getUsedHeight() + Helper.borderSize)

  frame:display()

  return true
end

function StandingOrders.cloneOrdersExecute()
  debugTrace("Executing clone orders from source " .. tostring(StandingOrders.sourceId) .. " to " .. tostring(#StandingOrders.targetIds) .. " targets")
  StandingOrders.cloneOrdersReset()
end

function StandingOrders.cloneOrdersCancel()
  StandingOrders.cloneOrdersReset()
  StandingOrders.reportSuccess({result = "cancelled"})
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
    elseif args.command == "unmark_source" then
      StandingOrders.MarkSourceOnMap()
    elseif args.command == "clone_orders" then
      local valid, errorData = StandingOrders.cloneOrdersPrepare(args)
      if valid then
        StandingOrders.cloneOrdersConfirm()
      else
        StandingOrders.reportError(errorData)
      end
    else
      debugTrace("ProcessRequest received unknown command: " .. tostring(args.command))
      StandingOrders.reportError({ info = "UnknownCommand" })
    end
  else
    debugTrace("ProcessRequest invoked but no MapMenu or Holomap available")
    StandingOrders.reportError({ info = "NoMap" })
  end
end

function StandingOrders.OrderNamesCollect()
  for orderDef, _ in pairs(StandingOrders.validOrders) do
    local buf = ffi.new("OrderDefinition")
    local found = C.GetOrderDefinition(buf, orderDef)
    if found then
      local orderName = ffi.string(buf.name)
      StandingOrders.validOrders[orderDef] = orderName
      debugTrace("Order definition " .. orderDef .. " resolved to name " .. StandingOrders.validOrders[orderDef])
    else
      debugTrace("Order definition " .. orderDef .. " could not be resolved")
    end
  end
end

function StandingOrders.Init()
  getPlayerId()
  ---@diagnostic disable-next-line: undefined-global
  RegisterEvent("StandingOrders.Request", StandingOrders.ProcessRequest)
  AddUITriggeredEvent("StandingOrders", "Reloaded")
  StandingOrders.mapMenu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(StandingOrders.mapMenu))
  StandingOrders.OrderNamesCollect()
end

Register_Require_With_Init("extensions.standing_orders.ui.standing_orders", StandingOrders, StandingOrders.Init)

return StandingOrders
