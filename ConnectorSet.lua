local Connector = require "Connector"

local M = {}

local ConnectorSet = {}

function M.new()
  local self = {
    connector_for = {},
    input_connectors = {},
    output_connectors = {},
    input_iter = 1,
    output_iter = 1,
  }
  return M.restore(self)
end

function M.restore(self)
  setmetatable(self, { __index = ConnectorSet })
  for connector in self:all_connectors() do
    Connector.restore(connector)
  end
  return self
end

function ConnectorSet:remove(connector)
  self.connector_for[connector.unit_number] = nil
  for _, list in ipairs{self.input_connectors, self.output_connectors} do
    for i, existing in ipairs(list) do
      if existing == connector then
        local len = #list
        list[i] = list[len]
        list[len] = nil
        return
      end
    end
  end
end

-- Returns #other_list if connector is found as the last element in other_list,
-- otherwise returns nil.
local function add(self, connector, to_list, other_list)
  for _, existing in ipairs(to_list) do
    if existing == connector then return end
  end

  self.connector_for[connector.unit_number] = connector

  to_list[#to_list+1] = connector
  for i, existing in ipairs(other_list) do
    if existing == connector then
      local l = #other_list
      other_list[i] = other_list[l]
      other_list[l] = nil

      if i == l then
        return i
      else
        return nil
      end
    end
  end
  return nil
end

function ConnectorSet:add_input(connector)
  local was_last_output = add(self, connector, self.input_connectors, self.output_connectors)
  if self.output_iter == was_last_output then
    self.output_iter = 1
  end
end

function ConnectorSet:add_output(connector)
  local was_last_input = add(self, connector, self.output_connectors, self.input_connectors)
  if self.input_iter == was_last_input then
    self.input_iter = 1
  end
end

function ConnectorSet:add(connector)
  if connector.mode == "input" then
    self:add_input(connector)
  else
    self:add_output(connector)
  end
end

local function next_connector(self, mode, predicate)
  local l = self[mode.."_connectors"]
  local i = self[mode.."_iter"]
  if i > #l then
    i = 1
  end

  local starting_index = i
  local connectors_to_remove = {}
  local connector_to_return
  repeat
    local connector = l[i]
    if connector then
      if connector:valid() then
        if predicate(connector) then
          self[mode.."_iter"] = i
          connector_to_return = connector
          break
        else
          i = i + 1
        end
      else
        connectors_to_remove[#connectors_to_remove+1] = connector
        i = i + 1
      end
    else
      i = 1
    end
  until i == starting_index

  for _, connector in pairs(connectors_to_remove) do
    self:remove(connector)
  end

  return connector_to_return
end

function ConnectorSet:next_input()
  return next_connector(self, "input", function(c) return c:ready_as_input() end)
end

function ConnectorSet:next_output()
  return next_connector(self, "output", function(c) return c:ready_as_output() end)
end

function ConnectorSet:all_connectors()
  local is = self.input_connectors
  local i_iter = 1
  local os = self.output_connectors
  local o_iter = 1

  return function()
    local connector = is[i_iter]
    if connector then
      i_iter = i_iter + 1
      return connector
    end
    connector = os[o_iter]
    if connector then
      o_iter = o_iter + 1
      return connector
    end
    return nil
  end
end

function ConnectorSet:is_empty()
  return not (next(self.input_connectors) or next(self.output_connectors))
end

return M