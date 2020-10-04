local BaseEditor = require "lualib.BaseEditor.BaseEditor"
local Connector = require "Connector"
local Network = require "Network"
local PipeMarker = require "PipeMarker"

local Editor = {}
local super = BaseEditor.class
setmetatable(Editor, { __index = super })

local debugp = function() end
local function _debugp(...)
  local info = debug.getinfo(2, "nl")
  local out = serpent.block(...)
  if info then
    log(info.name..":"..info.currentline..":"..out)
  else
    log("?:?:"..out)
  end
end
-- debugp = _debugp

local function nonproxy_name(name)
  return name:match("^pipelayer%-bpproxy%-(.*)$")
end

local function underground_counterpart_for_bpproxy(self, bpproxy)
  local name = nonproxy_name(bpproxy.name)
  return self:editor_surface_for_aboveground_surface(bpproxy.surface).find_entity(name, bpproxy.position)
end

local function ensure_chunk_exists(editor_surface, position)
  if not editor_surface.is_chunk_generated(position) then
    editor_surface.request_to_generate_chunks(position, 1)
    editor_surface.force_generate_chunk_requests()
  end
end

function Editor:toggle_connector_mode(player_index)
  local selected = game.players[player_index].selected
  if not selected or selected.name ~= "pipelayer-connector" then return end
  local surface = selected.surface
  local new_mode
  if self:is_editor_surface(surface) then
    local aboveground_surface = self:aboveground_surface_for_editor_surface(surface)
    local surface_connector = aboveground_surface.find_entity("pipelayer-connector", selected.position)
    new_mode = Network.for_entity(selected):toggle_connector_mode(surface_connector)
  elseif self:is_valid_aboveground_surface(surface) then
    local editor_surface = self:editor_surface_for_aboveground_surface(surface)
    local underground_connector = editor_surface.find_entity("pipelayer-connector", selected.position)
    new_mode = Network.for_entity(underground_connector):toggle_connector_mode(selected)
  end

  if new_mode then
    selected.surface.create_entity{
      name = "flying-text",
      position = selected.position,
      text = {"pipelayer-message.set-connector-mode", {"pipelayer-message.connector-mode-"..new_mode}},
    }
  end
end

local function is_connector(entity)
  if entity.name == "entity-ghost" then
    return entity.ghost_name == "pipelayer-connector" or entity.ghost_name == "pipelayer-output-connector"
  end
  return entity.name == "pipelayer-connector" or entity.name == "pipelayer-output-connector"
end

local function set_to_list(set)
  local out = {}
  for k in pairs(set) do
    out[#out+1] = k
  end
  return out
end

--- returns the network connected to entity with the highest ID, and true if any other networks were found
local function newest_connected_network(entity)
  local neighbours = entity.neighbours[1]
  local network_ids = {}
  local highest_network_id = 0
  local highest_network

  for _, neighbour in ipairs(neighbours) do
    local network = Network.for_entity(neighbour)
    local network_id = network.id
    network_ids[network_id] = true
    if network_id > highest_network_id then
      highest_network_id = network_id
      highest_network = network
    end
  end

  network_ids[highest_network_id] = nil

  return highest_network, next(network_ids) ~= nil
end

local function connect_underground_pipe(entity, aboveground_connector_entity)
  entity.active = false
  local main_network, found_other_networks = newest_connected_network(entity)
  if not main_network then
    main_network = Network.new(entity.surface)
  end

  main_network:add_underground_pipe(entity, aboveground_connector_entity)
  if found_other_networks then
    Network.absorb_from(entity)
  end
  return main_network
end

local function disconnect_underground_pipe(entity)
  local network = Network.for_entity(entity)
  if network then
    network:remove_underground_pipe(entity)
  end
end

local function opposite_direction(direction)
  return (direction + 4) % 8
end

local function on_built_aboveground_connector(self, creator, entity, stack)
  local surface = entity.surface
  local position = entity.position
  local direction = opposite_direction(entity.direction)
  local force = entity.force

  local is_output = entity.name == "pipelayer-output-connector"
  if is_output then
    -- replace with normal connector
    local replacement = surface.create_entity{
      name = "pipelayer-connector",
      direction = entity.direction,
      force = force,
      position = position,
    }
    entity.destroy()
    entity = replacement
  end

  local editor_surface = self:editor_surface_for_aboveground_surface(surface)
  ensure_chunk_exists(editor_surface, position)

  -- check for existing underground connector ghost
  local underground_ghost = editor_surface.find_entity("entity-ghost", position)
  if underground_ghost and is_connector(underground_ghost) then
    direction = underground_ghost.direction
  end

  local create_args = {
    name = "pipelayer-connector",
    position = position,
    direction = direction,
    force = force,
  }
  if not editor_surface.can_place_entity(create_args) then
    super.abort_build(creator, entity, stack, {"pipelayer-error.underground-obstructed"})
  else
    local underground_connector = editor_surface.create_entity(create_args)
    underground_connector.minable = false
    local network = connect_underground_pipe(underground_connector, entity)
    if is_output then
      network:set_connector_mode(entity, "output")
    end
  end
end

local function find_connector_ghosts(surface, position)
  return surface.find_entities_filtered{
    ghost_name = {"pipelayer-connector", "pipelayer-output-connector"},
    position = position,
  }
end

local function place_connector_ghost(args)
  local name = args.name
  local surface = args.surface
  local position = args.position
  local direction = args.direction
  local force = args.force
  local last_user = args.last_user
  ensure_chunk_exists(surface, position)

  if args.overwrite then
    local existing = find_connector_ghosts(surface, position)[1]
    if existing then
      existing.destroy()
    end
  end

  local create_args = {
    name = name,
    position = position,
    direction = direction,
    force = force,
    build_check_type = defines.build_check_type.ghost_place,
  }
  if surface.can_place_entity(create_args) then
    create_args.inner_name = create_args.name
    create_args.name = "entity-ghost"
    create_args.build_check_type = nil
    local ghost = surface.create_entity(create_args)
    ghost.last_user = last_user
    return ghost
  end
  return nil
end

local function on_built_connector_ghost_aboveground(self, ghost)
  local editor_surface = self:editor_surface_for_aboveground_surface(ghost.surface)
  local position = ghost.position
  if not next(find_connector_ghosts(editor_surface, position)) then
    place_connector_ghost{
      name = "pipelayer-connector",
      surface = editor_surface,
      position = ghost.position,
      direction = opposite_direction(ghost.direction),
      force = ghost.force,
      last_user = ghost.last_user,
    }
  end
end

local function on_built_connector_ghost_in_editor(self, ghost)
  local name = ghost.ghost_name
  local editor_surface = ghost.surface
  local position = ghost.position
  local direction = ghost.direction
  local force = ghost.force
  local last_user = ghost.last_user

  if #find_connector_ghosts(editor_surface, position) > 1 then
    -- bpproxy was already built here, so use direction as is
    ghost.destroy()
  else
    -- no bpproxy, use straight-through direction
    direction = opposite_direction(direction)
  end

  -- move ourselves above ground
  place_connector_ghost{
    name = name,
    surface = self:aboveground_surface_for_editor_surface(editor_surface),
    position = position,
    direction = direction,
    force = ghost.force,
    last_user = ghost.last_user,
  }
end

local function on_built_connector_ghost(self, ghost)
  local surface = ghost.surface
  if self:is_valid_aboveground_surface(surface) then
    return on_built_connector_ghost_aboveground(self, ghost)
  elseif self:is_editor_surface(surface) then
    return on_built_connector_ghost_in_editor(self, ghost)
  else
    ghost.destroy()
  end
end

local function on_built_connector_bpproxy_ghost_aboveground(self, bpproxy_ghost)
  local editor_surface = self:editor_surface_for_aboveground_surface(bpproxy_ghost.surface)
  place_connector_ghost{
    name = "pipelayer-connector",
    surface = editor_surface,
    position = bpproxy_ghost.position,
    direction = bpproxy_ghost.direction,
    force = bpproxy_ghost.force,
    last_user = bpproxy_ghost.last_user,
    overwrite = true,
  }
end

local function on_built_connector_bpproxy_ghost_in_editor(self, bpproxy_ghost)
  local editor_surface = bpproxy_ghost.surface
  local position = bpproxy_ghost.position

  -- check for connector ghost to move above ground
  local existing_connector_ghost = find_connector_ghosts(editor_surface, position)[1]
  if existing_connector_ghost then
    place_connector_ghost{
      name = existing_connector_ghost.ghost_name,
      surface = self:aboveground_surface_for_editor_surface(editor_surface),
      position = position,
      direction = existing_connector_ghost.direction,
      force = existing_connector_ghost.force,
      last_user = existing_connector_ghost.last_user,
      overwrite = true,
    }
  end

  place_connector_ghost{
    name = "pipelayer-connector",
    surface = editor_surface,
    position = bpproxy_ghost.position,
    direction = bpproxy_ghost.direction,
    force = bpproxy_ghost.force,
    last_user = bpproxy_ghost.last_user,
    overwrite = true,
  }
end


local function on_built_connector_bpproxy_ghost(self, bpproxy_ghost)
  local surface = bpproxy_ghost.surface
  local editor_surface = self:get_editor_surface(surface)
  if editor_surface == surface then
    on_built_connector_bpproxy_ghost_in_editor(self, bpproxy_ghost)
  elseif editor_surface then
    on_built_connector_bpproxy_ghost_aboveground(self, bpproxy_ghost)
  end
  bpproxy_ghost.destroy()
end

local function item_for_entity(entity)
  return next(entity.prototype.items_to_place_this)
end

function Editor:on_built_entity(event)
  local entity = event.created_entity
  if entity.name == "entity-ghost" then
    -- special handling for connector ghosts
    if entity.ghost_name == "pipelayer-connector" or entity.ghost_name == "pipelayer-output-connector" then
      return on_built_connector_ghost(self, entity)
    elseif entity.ghost_name == "pipelayer-bpproxy-pipelayer-connector" then
      return on_built_connector_bpproxy_ghost(self, entity)
    end
  end

  super.on_built_entity(self, event)
  local player_index = event.player_index
  local player = game.players[player_index]
  if not entity.valid or entity.name == "entity-ghost" then
    return
  end

  local stack = event.stack
  local surface = entity.surface

  if event.mod_name == "upgrade-planner" then
    -- work around https://github.com/Klonan/upgrade-planner/issues/10
    stack = {name = item_for_entity(entity), count = 1}
  end

  if is_connector(entity) then
    if self:is_valid_aboveground_surface(surface) then
      on_built_aboveground_connector(self, player, entity, stack)
    else
      super.abort_build(player, entity, stack, {"pipelayer-error.bad-surface"})
    end
  elseif self:is_editor_surface(surface) then
    connect_underground_pipe(entity)
  end
end

function Editor:on_robot_built_entity(event)
  local entity = event.created_entity
  local surface = entity.surface

  -- superclass will destroy bpproxy and create underground entity, so store info
  -- we need to find that underground entity
  local name = nonproxy_name(entity.name)
  local position = entity.position

  super.on_robot_built_entity(self, event)

  if name then
    local editor_surface = self:editor_surface_for_aboveground_surface(surface)
    local underground_entity = editor_surface.find_entity(name, position)
    connect_underground_pipe(underground_entity)
  end

  if entity.valid and is_connector(entity) then
    on_built_aboveground_connector(self, event.robot, entity, event.stack)
  end
end

local function on_mined_bpproxy(self, bpproxy)
  local counterpart = underground_counterpart_for_bpproxy(self, bpproxy)
  if counterpart then
    disconnect_underground_pipe(counterpart)
  end
end

local function on_mined_surface_connector(self, entity)
  local editor_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  local underground_connector = editor_surface.find_entity("pipelayer-connector", entity.position)
  disconnect_underground_pipe(underground_connector)
  underground_connector.destroy()
end

local function on_connector_ghost_removed(self, connector_ghost)
  local surface = self:counterpart_surface(connector_ghost.surface)
  local counterpart_ghost = surface.find_entity("entity-ghost", connector_ghost.position)
  if counterpart_ghost then
    counterpart_ghost.destroy()
  end
end

function Editor:on_pre_player_mined_item(event)
  super.on_pre_player_mined_item(self, event)
  local entity = event.entity
  if entity.name == "entity-ghost" and
     (entity.ghost_name == "pipelayer-connector" or entity.ghost_name == "pipelayer-output-connector") then
    on_connector_ghost_removed(self, entity)
  end
end

function Editor:on_player_mined_entity(event)
  super.on_player_mined_entity(self, event)
  local entity = event.entity
  local surface = entity.surface
  if self:is_editor_surface(surface) then
    disconnect_underground_pipe(entity)
  elseif self:is_valid_aboveground_surface(surface) then
    if entity.name == "pipelayer-connector" then
      on_mined_surface_connector(self, entity)
    elseif nonproxy_name(entity.name) then
      on_mined_bpproxy(self, entity)
    end
  end
end

function Editor:on_robot_mined_entity(event)
  local entity = event.entity
  local surface = entity.surface
  if self:is_valid_aboveground_surface(surface) then
    if entity.name == "pipelayer-connector" then
      on_mined_surface_connector(self, entity)
    elseif nonproxy_name(entity.name) then
      on_mined_bpproxy(self, entity)
    end
  end
  super.on_robot_mined_entity(self, event)
end

function Editor:on_player_rotated_entity(event)
  local entity = event.entity
  local surface = entity.surface
  if not self:is_editor_surface(surface) then return end

  local aboveground_surface = self:aboveground_surface_for_editor_surface(surface)
  local old_network = Network.for_entity(entity)
  local main_network, found_other_networks = newest_connected_network(entity)
  if old_network:is_singleton() and not main_network then
    return
  end

  old_network:remove_underground_pipe(entity)

  local surface_connector = aboveground_surface.find_entity("pipelayer-connector", entity.position)
  local new_network = connect_underground_pipe(entity, surface_connector)
end

function Editor:on_entity_died(event)
  local entity = event.entity
  if self:is_valid_aboveground_surface(entity.surface) and entity.name == "pipelayer-connector" then
    on_mined_surface_connector(self, entity)
  end
end

function Editor:on_tick(event)
  Network.update_all(event)
  super.on_tick(self, event)
end

------------------------------------------------------------------------------------------------------------------------
-- deconstruction

local function find_in_area(args)
  local area = args.area
  if area.left_top.x >= area.right_bottom.x or area.left_top.y >= area.right_bottom.y then
    args.position = area.left_top
    args.area = nil
  end
  return args.surface.find_entities_filtered(args)
end

local function area_contains_connectors(surface, area)
  return
    find_in_area{
      surface = surface,
      area = area,
      name = "pipelayer-connector",
      limit = 1,
    }[1] or
    find_in_area{
      surface = surface,
      area = area,
      name = "entity-ghost",
      ghost_name = {"pipelayer-connector", "pipelayer-output-connector"},
      limit = 1,
    }[1]
end

local previous_connector_ghost_deconstruction_tick
local previous_connector_ghost_deconstruction_player_index

local function remove_connector_deconstruction_proxies(aboveground_surface, area)
  local bpproxies = aboveground_surface.find_entities_filtered{
    name = "pipelayer-bpproxy-pipelayer-connector",
    area = area,
  }
  for _, bpproxy in pairs(bpproxies) do
    local aboveground_connector = aboveground_surface.find_entity("pipelayer-connector", bpproxy.position)
    if aboveground_connector then
      aboveground_connector.order_deconstruction(aboveground_connector.force)
    end
    bpproxy.destroy()
  end
end

local function on_player_deconstructed_surface_area(self, player, area, tool)
  local aboveground_surface = player.surface
  if not area_contains_connectors(aboveground_surface, area) and
     not (player.index == previous_connector_ghost_deconstruction_player_index and
     game.tick == previous_connector_ghost_deconstruction_tick) then
    return
  end
  local editor_surface = self:editor_surface_for_aboveground_surface(aboveground_surface)
  local underground_entities = self:order_underground_deconstruction(player, editor_surface, area, tool)
  remove_connector_deconstruction_proxies(aboveground_surface, area)

  if next(underground_entities) and
     settings.get_player_settings(player)["pipelayer-deconstruction-warning"].value then
    player.print({"pipelayer-message.marked-for-deconstruction", #underground_entities})
  end
end

local function on_player_deconstructed_underground_area(self, player, area, tool)
  local aboveground_surface = self:aboveground_surface_for_editor_surface(player.surface)
  remove_connector_deconstruction_proxies(aboveground_surface, area)
end

local function on_player_deconstructed_area(self, player, area, tool)
  local surface = player.surface
  if self:is_valid_aboveground_surface(surface) then
    return on_player_deconstructed_surface_area(self, player, area, tool)
  elseif self:is_editor_surface(surface) then
    return on_player_deconstructed_underground_area(self, player, area, tool)
  end
end

local function checkIfNeedToDeconstruct(event)
  local player = game.players[event.player_index]
  if settings.get_player_settings(player)["pipelayer-deconstruct"].value == "alt-not-pressed" then
      return event.alt
  else
    return not event.alt
  end
end

function Editor:on_player_deconstructed_area(event)
  if checkIfNeedToDeconstruct(event) then return end
  local player = game.players[event.player_index]
  on_player_deconstructed_area(self, player, event.area, player.cursor_stack)
end

function Editor:on_pre_ghost_deconstructed(event)
  super.on_pre_ghost_deconstructed(self, event)
  local ghost = event.ghost
  if is_connector(ghost) then
    previous_connector_ghost_deconstruction_player_index = event.player_index
    previous_connector_ghost_deconstruction_tick = game.tick
    on_connector_ghost_removed(self, ghost)
  end
end

function Editor:on_cancelled_deconstruction(event)
  super.on_cancelled_deconstruction(self, event)
  local entity = event.entity
  if entity.valid and is_connector(entity) then
    local counterpart = self:counterpart_surface(entity.surface).find_entity("pipelayer-connector", entity.position)
    if counterpart then
      counterpart.cancel_deconstruction(counterpart.force)
    end
  end
end

------------------------------------------------------------------------------------------------------------------------
-- capture underground pipes as bpproxy ghosts

local function is_output_connector(entity)
  return entity and Connector.for_below_unit_number(entity.unit_number).mode == "output"
end

local function checkIfNeedToBlueprint(event)
  local player = game.players[event.player_index]
  if settings.get_player_settings(player)["pipelayer-blueprint"].value == "alt-not-pressed" then
      return event.alt
  else
    return not event.alt
  end
end

local function on_player_setup_aboveground_blueprint(self, event)
  local player = game.players[event.player_index]
  local surface = player.surface
  local editor_surface
  if self:is_editor_surface(surface) then
    editor_surface = surface
  elseif self:is_valid_aboveground_surface(surface) then
    editor_surface = self:editor_surface_for_aboveground_surface(surface)
  else
    return
  end

  local bp, bp_to_world = self:capture_underground_entities_in_blueprint(event, not checkIfNeedToBlueprint(event))
  local bp_entities = bp.get_blueprint_entities()
  if not bp_entities then return end

  for _, bp_entity in ipairs(bp_entities) do
    if bp_entity.name == "pipelayer-connector" then
      local position = bp_to_world(bp_entity.position)
      local ug_pipe = editor_surface.find_entity("pipelayer-connector", position)
      if is_output_connector(ug_pipe) then
        bp_entity.name = "pipelayer-output-connector"
      end
    end
  end

  bp.set_blueprint_entities(bp_entities)
end

function Editor:on_player_setup_blueprint(event)
  on_player_setup_aboveground_blueprint(self, event)
  if event.item == "cut-paste-tool" and checkIfNeedToDeconstruct(event) then
    local player = game.players[event.player_index]
    on_player_deconstructed_area(self, player, event.area, nil)
  end
end

---------------------------------------------------------------------------------------------------
-- other mod compatibility

local function to_set(t)
  local out = {}
  for _, elem in ipairs(t) do
    out[elem] = true
  end
  return out
end

local function set_diff(s1, s2)
  local added = {}
  local removed = {}
  for e in pairs(s1) do
    if not s2[e] then
      removed[e] = true
    end
  end
  for e in pairs(s2) do
    if not s1[e] then
      added[e] = true
    end
  end
  return added, removed
end

local old_unit_number
local old_neighbours
function Editor:on_script_raised_destroy(event)
  super.on_script_raised_destroy(self, event)

  local entity = event.entity
  if not entity or not entity.valid then return end
  if self:is_valid_aboveground_surface(entity.surface) then
    if entity.name == "pipelayer-connector" then
      on_mined_surface_connector(self, entity)
    end
  elseif self:is_editor_surface(entity.surface) then
    if entity.type == "pipe-to-ground" then
      old_unit_number = entity.unit_number
      old_neighbours = to_set(entity.neighbours[1] or {})
    end
  end
end

function Editor:on_script_raised_built(event)
  super.on_script_raised_built(self, event)

  local entity = event.entity or event.created_entity
  if not entity or not entity.valid then return end
  if entity.type ~= "pipe-to-ground" then return end
  if not self:is_editor_surface(entity.surface) then return end

  local new_neighbours = to_set(entity.neighbours[1] or {})
  local added, removed = set_diff(old_neighbours or {}, new_neighbours)
  local network = old_unit_number and Network.for_unit_number(old_unit_number)
  if network then
    network:underground_pipe_replaced(old_unit_number, entity, added, removed)
  end
end

---------------------------------------------------------------------------------------------------
-- pipe marker rendering

function Editor:on_player_cursor_stack_changed(event)
  local player_index = event.player_index
  local player = game.players[player_index]
  local editor_surface = self:get_editor_surface(player.surface)
  if not editor_surface then return end

  PipeMarker.on_cursor_stack_changed(player_index, editor_surface)
end

function Editor:on_player_changed_position(event)
  local player_index = event.player_index
  local player = game.players[player_index]
  local editor_surface = self:get_editor_surface(player.surface)
  if not editor_surface then return end

  local cursor_stack = player.cursor_stack
  if not cursor_stack or not cursor_stack.valid_for_read then return end
  if cursor_stack.name ~= "pipelayer-connector" then return end

  PipeMarker.on_player_changed_position(player_index, editor_surface)
end

local M = {}

function M.new()
  local self = BaseEditor.new("pipelayer")
  self.valid_editor_types = {
    "blueprint", "blueprint-book", "deconstruction-item", "upgrade-item",
    "pipe", "pipe-to-ground",
  }
  return M.restore(self)
end

function M.restore(self)
  return setmetatable(self, { __index = Editor })
end

function M.instance()
  if global.editor then
    return M.restore(global.editor)
  else
    return M.new()
  end
end

return M
