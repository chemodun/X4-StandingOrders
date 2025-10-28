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

	UniverseID GetPlayerID(void);
  uint32_t GetOrders(Order* result, uint32_t resultlen, UniverseID controllableid);
	uint32_t CreateOrder(UniverseID controllableid, const char* orderid, bool default);
	bool EnableOrder(UniverseID controllableid, size_t idx);
]]

local StandingOrders = {
  playerId = 0,
  mapMenu = {},
  validOrders = {
    SingleBuy  = true,
    SingleSell = true,
  },
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

function StandingOrders.recordResult(data)
  debugTrace("recordResult called for command ".. tostring(data and data.command) .. " with result " .. tostring(data and data.result))
  if StandingOrders.playerId ~= 0 then
    local payload = data or {}
    SetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersResponse", payload)
    AddUITriggeredEvent("Trade_Loop_Manager", "Response")
  end
end

function StandingOrders.reportError(data, extraInfo)
  local data = data or {}
  data.result = "error"
  if extraInfo == nil then
    extraInfo = {}
  end
  for k, v in pairs(extraInfo) do
    data[k] = v
  end
  StandingOrders.recordResult(data)

  local message = "StandingOrders error"
  if data.info then
    message = message .. ": " .. tostring(data.info)
  end
  if data.detail then
    message = message .. " (" .. tostring(data.detail) .. ")"
  end

  DebugError(message)
end

function StandingOrders.reportSuccess(data)
  data = data or {}
  data.result = "success"
  StandingOrders.recordResult(data)
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
      table.insert(orders, order)
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
  if not C.IsComponentOperational(shipId) then
    return false, { info = "ShipNotOperational" }
  end
  return true
end

function StandingOrders.isValidSourceShip(sourceId)
  local sourceId = toUniverseId(sourceId)
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
    if not StandingOrders.validOrders[order.order] then
      return false, { info = "InvalidStandingOrder", detail = "order=" .. tostring(order.order) }
    end
  end
  return true
end

function StandingOrders.getArgs()
  if StandingOrders.playerId == 0 then
    debugTrace("getArgs unable to resolve player id")
  else
    local list = GetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersRequest")
    if type(list) == "table" then
      debugTrace("getArgs retrieved " .. tostring(#list) .. " entries from blackboard")
      local args = list[#list]
      SetNPCBlackboard(StandingOrders.playerId, "$StandingOrdersRequest", nil)
      return args
    elseif list ~= nil then
      debugTrace("getArgs received non-table payload of type " .. type(list))
    else
      debugTrace("getArgs found no blackboard entries for player " .. tostring(StandingOrders.playerId))
    end
  end
  return nil
end


function StandingOrders.MarkSourceOnMap(args)
  local source = tostring(args.source)
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
    StandingOrders.reportError(args)
    return
  end
  StandingOrders.reportSuccess(args)
end

function StandingOrders.ProcessRequest(_, _)
  if StandingOrders.mapMenu and StandingOrders.mapMenu.holomap and (StandingOrders.mapMenu.holomap ~= 0) then
    local args = StandingOrders.getArgs()
    if not args or type(args) ~= "table" then
      debugTrace("ProcessRequest invoked without args or invalid args")
      StandingOrders.reportError("missing_args")
      return
    end
    debugTrace("ProcessRequest received command: " .. tostring(args.command))
    if args.command == "mark_source" or args.command == "unmark_source" then
      StandingOrders.MarkSourceOnMap(args)
    else if args.command == "check_source" then
      local valid, errorData = StandingOrders.isValidSourceShip(args.source)
      if valid then
        args.info = "ValidSource"
        StandingOrders.reportSuccess(args)
      else
        StandingOrders.reportError(args, errorData)
      end
    else
      debugTrace("ProcessRequest received unknown command: " .. tostring(args.command))
      StandingOrders.reportError(args, { info = "UnknownCommand" })
    end
  else
    debugTrace("ProcessRequest invoked but no MapMenu or Holomap available")
    StandingOrders.reportError(args, { info = "NoMap" })
  end
end

function StandingOrders.Init()
  getPlayerId()
  ---@diagnostic disable-next-line: undefined-global
  RegisterEvent("StandingOrders.Request", StandingOrders.ProcessRequest)
  AddUITriggeredEvent("Trade_Loop_Manager", "Reloaded")
  StandingOrders.mapMenu = Lib.Get_Egosoft_Menu("MapMenu")
  debugTrace("MapMenu is " .. tostring(StandingOrders.mapMenu))
end

Register_Require_With_Init("extensions.standing_orders.ui.standing_orders", StandingOrders, StandingOrders.Init)

return StandingOrders
