require('util')

-- add option for placeholder fish, removing proxies on leave to prevent chasing robots
-- trash everything ui button - provide *

-- work on the paste-in-to-new-entities stuff in scaling, test

-- potentially handle station rename - move settings if the last station with that name is renamed, maybe?

-- make sure there's a proxy player in the wagon
local function ensure_proxy(entity)
  if not global.wagons[entity.unit_number] then
    global.wagons[entity.unit_number] = {}
  end
  if global.wagons[entity.unit_number].proxy and global.wagons[entity.unit_number].proxy.valid then
    return
  else
    if not entity.get_driver() then
      local proxy = entity.surface.create_entity({
        name = "logistic-cargo-wagon-proxy-player",
        position = entity.position,
        force = entity.force,
      })
      entity.set_driver(proxy)
      global.wagons[entity.unit_number].proxy = proxy
    end
  end
end

-- remove a proxy from the wagon if there is one
local function ensure_no_proxy(entity)
  if global.wagons[entity.unit_number] and global.wagons[entity.unit_number].proxy then
    if global.wagons[entity.unit_number].proxy.valid then
      global.wagons[entity.unit_number].proxy.destroy()
    end
    global.wagons[entity.unit_number].proxy = nil
  end
end

-- split the stack before transfer if transferring into an occupied slot, as a transfer overflowing into a barred slot is causing spills
local function safe_transfer(source_inventory, source_stack, dest_inventory)
  if not dest_inventory.can_insert(source_stack) then
    return
  end
  local stack_size = game.item_prototypes[source_stack.name].stack_size
  for i = 1, #dest_inventory do
    local dest_stack = dest_inventory[i]
    if not dest_stack.valid_for_read and dest_stack.can_set_stack(source_stack) then
      -- we're good to transfer the whole thing, just return the transfer attempt
      return dest_stack.transfer_stack(source_stack)
    elseif dest_stack.valid_for_read and dest_stack.name == source_stack.name and dest_stack.count < stack_size then
      -- occupied but not full-check max stack size for potential split before transfer
      local max_transfer_count = stack_size - dest_stack.count
      if source_stack.count < max_transfer_count then
        return dest_stack.transfer_stack(source_stack)
      else
        -- need to split this stack
        for j = 1, #source_inventory do
          local split_stack = source_inventory[j]
          if not split_stack.valid_for_read and split_stack.can_set_stack(source_stack) then
            -- valid spot to clone into for split
            split_stack.set_stack(source_stack)
            split_stack.count = source_stack.count - max_transfer_count
            source_stack.count = max_transfer_count
            -- stack's now small enough to fit without spilling, move it in
            return dest_stack.transfer_stack(source_stack)
          end
        end
      end
    end
  end
end

-- check this active proxy for anything to transfer to or from the wagon's inventory
local function sync_proxy_inventory(proxy, carriage)
  -- track whether anything changes for switching the train mode to "bump" inactivity conditions in a train's schedule
  local refresh = false

  local config = global.wagons[carriage.unit_number]
  if carriage.train.station and carriage.train.station.backer_name then
    local station_config = config.stations[carriage.train.station.backer_name]
    if station_config and proxy and proxy.valid and proxy.unit_number == carriage.get_driver().unit_number then
      -- we're parked at a station, the right driver is in the carriage, we're good to proceed
      local carriage_cargo_inv = carriage.get_inventory(defines.inventory.cargo_wagon)
      local proxy_main_inv = proxy.get_inventory(defines.inventory.player_main)
      local proxy_trash_inv = proxy.get_inventory(defines.inventory.player_trash)

      global.active_wagons[carriage.unit_number] = proxy

      -- scan the main inventory for anything to transfer to the train
      if not proxy_main_inv.is_empty() then
        for i = 1, #proxy_main_inv do
          local stack = proxy_main_inv[i]
          if stack.valid_for_read then
            if safe_transfer(proxy_main_inv, stack, carriage_cargo_inv) then
              break
            end
          end
        end
        carriage_cargo_inv.sort_and_merge()
      end

      -- get the inventory to subtract counts from requests
      local carriage_contents = carriage_cargo_inv.get_contents()
      local main_inv_contents = proxy_main_inv.get_contents()
      -- set the requests according to what's in requests minus what's in the inventory, stopping the request completely if there's any in the proxy's inventory still
      if station_config.requests then
        for i = 1, proxy.request_slot_count do
          local request = station_config.requests[i]
          if request then
            local count = request.count - (carriage_contents[request.name] or 0)
            if count > 0 and carriage_cargo_inv.can_insert({ name = request.name, count = 1 }) and not main_inv_contents[request.name] then
              proxy.set_request_slot({ name = request.name, count = count }, i)
            else
              proxy.clear_request_slot(i)
            end
          else
            proxy.clear_request_slot(i)
          end
        end
      end

      -- find any empty slots to put trash in
      if station_config.provides then
        local slot_cursor = 1
        for i = 1, #proxy_trash_inv do
          if not proxy_trash_inv[i].valid_for_read then
            -- scan inv for anything in the list to add (using the same incrementer so we don't check slots twice)
            while slot_cursor <= #carriage_cargo_inv do
              local carriage_stack = carriage_cargo_inv[slot_cursor]
              slot_cursor = slot_cursor + 1
              if carriage_stack.valid_for_read and station_config.provides[carriage_stack.name] then
                proxy_trash_inv[i].transfer_stack(carriage_stack)
                break
              end
            end
          end
        end
      end

      -- count up the total stuff in the cargo, see if it's changed from last time to trigger a refresh of the train's mode
      -- (all in the service of getting the inactivity condition to obey the bots)
      local carriage_cargo_count = 0
      local carriage_contents = carriage_cargo_inv.get_contents()
      for _, count in pairs(carriage_cargo_inv.get_contents()) do
        carriage_cargo_count = carriage_cargo_count + count
      end
      -- remove the placeholder fish if there is one
      -- (this is in the service of getting the empty condition to not trigger when the last of the wagon is in the proxy's trash)
      if carriage_contents["coin"] then
        carriage_cargo_count = carriage_cargo_count - carriage_cargo_inv.remove({ name = "coin", count = 1 })
      end

      if config.carriage_cargo_count ~= carriage_cargo_count then
        config.carriage_cargo_count = carriage_cargo_count
        refresh = true
      end

      -- same deal for trash
      local trash_inv_count = 0
      for _, count in pairs(proxy_trash_inv.get_contents()) do
        trash_inv_count = trash_inv_count + count
      end
      if config.trash_inv_count ~= trash_inv_count then
        config.trash_inv_count = trash_inv_count
        refresh = true
      end

      if carriage_cargo_count == 0 and trash_inv_count > 0 then
        -- insert placeholder since it's not present but there's trash and no carriage cargo
        carriage_cargo_inv.insert({ name = "coin", count = 1 })
      end
    end
  end
  return refresh
end

-- fires every 15 ticks while a train with active wagons is parked at a station
local function check_active_proxies(event)
  -- iterate in reverse so we can delete any that have issues
  local refresh_trains = {}
  for i = #global.active_proxies, 1, -1 do
    local proxy = global.active_proxies[i]
    if proxy.valid and proxy.vehicle and proxy.vehicle.valid then
      -- get a return value on if any changes were made, mark the train
      local refresh = sync_proxy_inventory(proxy, proxy.vehicle)
      if refresh then
        refresh_trains[proxy.vehicle.train] = true
      end
    else
      table.remove(global.active_proxies, i)
    end
  end
  -- touch each train that had a refresh
  for train in pairs(refresh_trains) do
    train.manual_mode = false
  end
  -- unregister if none left
  if not next(global.active_proxies) then
    script.on_nth_tick(15, nil)
  end
end

-- checking whether a train split disconnects logistic wagons from all their locomotives; in that case, make them minable
local function on_train_created(event)
  local train = event.train
  if #train.locomotives.front_movers == 0 and #train.locomotives.back_movers == 0 then
    -- no engines, clear any proxies that exist for potential mining
    for _, carriage in ipairs(train.cargo_wagons) do
      if carriage.name == "logistic-cargo-wagon" then
        ensure_no_proxy(carriage)
      end
    end
  end
end
script.on_event(defines.events.on_train_created, on_train_created)

-- When a wagon is gone, take out its proxy.
local function on_entity_gone(event)
  if event.entity and event.entity.valid and event.entity.name == "logistic-cargo-wagon" then
    local unit_number = event.entity.unit_number
    if global.wagons[unit_number] then
      if global.wagons[unit_number].proxy and global.wagons[unit_number].proxy.valid then
        global.wagons[unit_number].proxy.destroy()
      end
      global.wagons[unit_number] = nil
    end
  end
end
script.on_event(defines.events.on_pre_player_mined_item, on_entity_gone)
script.on_event(defines.events.on_entity_died, on_entity_gone)
script.on_event(defines.events.script_raised_destroy, on_entity_gone)

local manual_modes = {
  [defines.train_state.manual_control_stop] = true,
  [defines.train_state.manual_control] = true,
}
local function on_train_changed_state(event)
  local train = event.train
  if train.state == defines.train_state.wait_station and train.station then
    local station = train.station.backer_name
    -- parked at a station, see about setting requests
    for _, carriage in ipairs(train.cargo_wagons) do
      if carriage.name == "logistic-cargo-wagon" then
        local config = global.wagons[carriage.unit_number]
        if not config then
          global.wagons[carriage.unit_number] = {}
          config = global.wagons[carriage.unit_number]
        end
        if not config.proxy then
          ensure_proxy(carriage)
        end
        if config and config.stations and config.stations[station] and not global.active_wagons[carriage.unit_number] then
          table.insert(global.active_proxies, config.proxy)
          sync_proxy_inventory(config.proxy, carriage)
        end
      end
    end
    if next(global.active_proxies) then
      script.on_nth_tick(15, check_active_proxies)
    end
  elseif train.state == defines.train_state.on_the_path or manual_modes[train.state] then
    -- not at a station - kill any active requests, move anything in inventory and trash to wagon if possible then spill
    for _, carriage in ipairs(train.cargo_wagons) do
      if carriage.name == "logistic-cargo-wagon" then
        if global.active_wagons[carriage.unit_number] then
          local config = global.wagons[carriage.unit_number]
          global.active_wagons[carriage.unit_number] = nil
          if config.proxy and config.proxy.valid then
            -- everything's in place so this seems to be a normal mode change, safe to do one final inventory sync
            local proxy = config.proxy
            local carriage_cargo_inv = carriage.get_inventory(defines.inventory.cargo_wagon)
            local proxy_main_inv = proxy.get_inventory(defines.inventory.player_main)
            local proxy_trash_inv = proxy.get_inventory(defines.inventory.player_trash)

            -- one last inventory sync
            sync_proxy_inventory(proxy, proxy.vehicle)

            -- remove the placeholder if the sync just put one there
            carriage_cargo_inv.remove({ name = "coin", count = 1 })

            -- clear trash into carriage or else proxy main inventory
            if not proxy_trash_inv.is_empty() then
              for i = 1, #proxy_trash_inv do
                local trash_stack = proxy_trash_inv[i]
                if trash_stack.valid_for_read then
                  if not safe_transfer(proxy_trash_inv, trash_stack, carriage_cargo_inv) then
                    safe_transfer(proxy_trash_inv, trash_stack, proxy_main_inv)
                  end
                end
              end
              carriage_cargo_inv.sort_and_merge()
              proxy_main_inv.sort_and_merge()
            end

            -- move main to cargo or else spill
            if not proxy_main_inv.is_empty() then
              for i = 1, #proxy_main_inv do
                local inv_stack = proxy_main_inv[i]
                if inv_stack.valid_for_read then
                  safe_transfer(proxy_main_inv, inv_stack, carriage_cargo_inv)
                  if inv_stack.valid_for_read then
                    proxy.surface.spill_item_stack(proxy.position, inv_stack, nil, proxy.force)
                    inv_stack.clear()
                  end
                end
              end
              carriage_cargo_inv.sort_and_merge()
            end

            -- clear all requests
            for i = 1, proxy.request_slot_count do
              proxy.clear_request_slot(i)
            end

            for i = #global.active_proxies, 1, -1 do
              local active_proxy = global.active_proxies[i]
              if active_proxy.valid and active_proxy.unit_number == proxy.unit_number then
                table.remove(global.active_proxies, i)
              elseif not active_proxy.valid then
                table.remove(global.active_proxies, i)
              end
            end
          end
        end

        if manual_modes[train.state] then
          -- todo wrap a setting around doing this always instead of just when going into manual mode to prevent chasing bots
          ensure_no_proxy(carriage)
        end
      end
    end
  end
end
script.on_event(defines.events.on_train_changed_state, on_train_changed_state)

-- if they're both our entities, copy over the whole settings table other than the proxy
local function on_entity_settings_pasted(event)
  if event.source.name == "logistic-cargo-wagon" and event.destination.name == "logistic-cargo-wagon" and global.wagons[event.source.unit_number] then
    local new_dest_settings = util.table.deepcopy(global.wagons[event.source.unit_number])

    if global.wagons[event.destination.unit_number] and global.wagons[event.source.unit_number].proxy then
      new_dest_settings.proxy = global.wagons[event.destination.unit_number].proxy
    else
      new_dest_settings.proxy = nil
    end
    global.wagons[event.destination.unit_number] = new_dest_settings
  end
end
script.on_event(defines.events.on_entity_settings_pasted, on_entity_settings_pasted)


-- GUI time!
-- populate the dropdown to select stations
local function get_station_select_dropdown(train)
  local items = {}
  local schedule = train.schedule
  if schedule and schedule.records and #schedule.records > 0 then
    for _, record in ipairs(schedule.records) do
      if record.station then
        table.insert(items, record.station)
      end
    end
  else
    items[1] = {"logistic-cargo-wagon.no-station"}
  end
  return items
end

-- redraw the item selections in an open gui, since deleting one from the middle or making a conflicting request can impact the rest of the config
local function update_gui_item_selections(player, config_flow)
  local entity = player.opened
  local config = global.wagons[entity.unit_number]
  local dropdown = config_flow.logistic_cargo_config_station_dropdown
  local station = dropdown.items[dropdown.selected_index]
  local split_flow = config_flow.logistic_cargo_config_split_flow
  local request_flow = split_flow.logistic_cargo_config_request_flow
  local provide_flow = split_flow.logistic_cargo_config_provide_flow

  if config and config.stations and config.stations[station] then
    -- iterate and set
    local next_cursor
    if not config.stations[station].requests then
      config.stations[station].requests = {}
    end
    local requests = config.stations[station].requests
    if not config.stations[station].provides then
      config.stations[station].provides = {}
    end
    local provides = config.stations[station].provides
    for i = 1, 12 do
      local request_subflow = request_flow[string.format("logistic_cargo_config_request_flow_%d", i)]
      local request_button = request_subflow[string.format("logistic_cargo_config_request_button_%d", i)]
      local request_textbox = request_subflow[string.format("logistic_cargo_config_request_text_%d", i)]
      local provide_button = provide_flow[string.format("logistic_cargo_config_provide_button_%d", i)]

      local provide
      if next_cursor ~= false then
        next_cursor, provide = next(provides, next_cursor)
        if not provide then
          next_cursor = false
        end
      end
      if provide then
        provide_button.elem_value = next_cursor
      else
        provide_button.elem_value = nil
      end

      local request = requests[i]
      if request then
        request_button.elem_value = request.name
        request_textbox.text = request.count
      else
        request_button.elem_value = nil
        request_textbox.text = ""
      end
    end
  else
    -- clear all
    for i = 1, 12 do
      local request_subflow = request_flow[string.format("logistic_cargo_config_request_flow_%d", i)]
      local request_button = request_subflow[string.format("logistic_cargo_config_request_button_%d", i)]
      local request_textbox = request_subflow[string.format("logistic_cargo_config_request_text_%d", i)]
      local provide_button = provide_flow[string.format("logistic_cargo_config_provide_button_%d", i)]

      provide_button.elem_value = nil
      request_button.elem_value = nil
      request_textbox.text = ""
    end
  end
end

-- draw gui elements
local function on_gui_opened(event)
  if event.entity and event.entity.name == "logistic-cargo-wagon" then
    local player = game.players[event.player_index]
    if player.permission_group.allows_action(defines.input_action.set_logistic_filter_item) then
      if player.gui.left.logistic_cargo_config then
        player.gui.left.logistic_cargo_config.destroy()
      end
      local frame = player.gui.left.add({
        name = "logistic_cargo_config",
        type = "frame",
        direction = "vertical",
      })
      local config_flow = frame.add({
        name = "logistic_cargo_config_flow",
        type = "flow",
        direction = "vertical",
      })

      -- station dropdown
      local dropdown = config_flow.add({
        name = "logistic_cargo_config_station_dropdown",
        type = "drop-down",
        items = get_station_select_dropdown(event.entity.train),
        selected_index = 1,
        tooltip = {"logistic-cargo-wagon.config-station-tooltip"},
      })

      local split_flow = config_flow.add({
        name = "logistic_cargo_config_split_flow",
        type = "flow",
        direction = "horizontal",
      })
      
      local request_flow = split_flow.add({
        name = "logistic_cargo_config_request_flow",
        type = "flow",
        direction = "vertical",
      })
      local request_label = request_flow.add({
        name = "logistic_cargo_config_request_label",
        type = "label",
        caption = {"logistic-cargo-wagon.request-label"},
      })

      local provide_flow = split_flow.add({
        name = "logistic_cargo_config_provide_flow",
        type = "flow",
        direction = "vertical",
      })
      local provide_label = provide_flow.add({
        name = "logistic_cargo_config_provide_label",
        type = "label",
        caption = {"logistic-cargo-wagon.provide-label"},
      })

      for i = 1, 12 do
        local request_subflow = request_flow.add({
          name = string.format("logistic_cargo_config_request_flow_%d", i),
          type = "flow",
          direction = "horizontal",
        })
        request_subflow.add({
          name = string.format("logistic_cargo_config_request_button_%d", i),
          type = "choose-elem-button",
          style = "slot_button",
          elem_type = "item",
        })
        request_subflow.add({
          name = string.format("logistic_cargo_config_request_text_%d", i),
          type = "textfield",
        })

        provide_flow.add({
          name = string.format("logistic_cargo_config_provide_button_%d", i),
          type = "choose-elem-button",
          style = "slot_button",
          elem_type = "item",
        })
      end

      local copy_button = config_flow.add({
        name = "logistic_cargo_config_copy_button",
        type = "button",
        caption = {"logistic-cargo-wagon.config-copy-label"},
        tooltip = {"logistic-cargo-wagon.config-copy-tooltip"},
      })
      update_gui_item_selections(player, config_flow)
    end
  end
end
script.on_event(defines.events.on_gui_opened, on_gui_opened)

local function on_gui_closed(event)
  if event.entity and event.entity.name == "logistic-cargo-wagon" then
    local player = game.players[event.player_index]
    if player.gui.left.logistic_cargo_config then
      player.gui.left.logistic_cargo_config.destroy()
    end
  end
end
script.on_event(defines.events.on_gui_closed, on_gui_closed)

local function logistic_cargo_config_request_change(event)
  local player = game.players[event.player_index]
  local entity = player.opened
  local config = global.wagons[entity.unit_number]
  local config_flow = player.gui.left.logistic_cargo_config.logistic_cargo_config_flow
  local dropdown = config_flow.logistic_cargo_config_station_dropdown
  local station = dropdown.items[dropdown.selected_index]
  if event.element.type == "textfield" and event.element.text == "" then
    return
  end
  if not config.stations then
    config.stations = {}
  end
  if not config.stations[station] then
    config.stations[station] = {}
  end

  -- rebuild the whole table of requests, then update
  local requests = {}
  local items_requested = {}
  local i = 1
  for _, child in ipairs(config_flow.logistic_cargo_config_split_flow.logistic_cargo_config_request_flow.children) do
    local choose_elem = child[string.format("logistic_cargo_config_request_button_%d", i)]
    local textbox = child[string.format("logistic_cargo_config_request_text_%d", i)]
    if choose_elem then
      if choose_elem.elem_value and not items_requested[choose_elem.elem_value] then
        -- add a request for this item
        items_requested[choose_elem.elem_value] = true
        -- calculate the max value
        local max_capacity = game.item_prototypes[choose_elem.elem_value].stack_size * 40
        local text_int = tonumber(textbox.text)
        local count
        if text_int and text_int <= max_capacity and text_int > 0 then
          -- within bounds, set
          count = text_int
        elseif text_int and text_int == 0 then
          -- do nothing, causing the entry to be removed
        else
          -- use existing config, or else the default max size
          if config.stations[station].requests and config.stations[station].requests[i] then
            count = config.stations[station].requests[i].count
          else
            count = max_capacity
          end
        end
        if count then
          table.insert(requests, { name = choose_elem.elem_value, count = count })
        end
      end
      i = i + 1
    end
  end
  config.stations[station].requests = requests

  -- scan for if we're providing this item, remove if so
  if config.stations[station].provides then
    for item in pairs(config.stations[station].provides) do
      if items_requested[item] then
        config.stations[station].provides[item] = nil
      end
    end
  end

  -- tables are up to date, call for a refresh to bring the elements into line
  update_gui_item_selections(player, config_flow)
  entity.last_user = game.players[event.player_index]
end

local function logistic_cargo_config_provide_change(event)
  local player = game.players[event.player_index]
  local entity = player.opened
  local config = global.wagons[entity.unit_number]
  local config_flow = player.gui.left.logistic_cargo_config.logistic_cargo_config_flow
  local dropdown = config_flow.logistic_cargo_config_station_dropdown
  local station = dropdown.items[dropdown.selected_index]
  if not config.stations then
    config.stations = {}
  end
  if not config.stations[station] then
    config.stations[station] = {}
  end

  -- rebuild provides table
  local provides = {}
  for _, child in ipairs(config_flow.logistic_cargo_config_split_flow.logistic_cargo_config_provide_flow.children) do
    if child.type == "choose-elem-button" and child.elem_value then
      provides[child.elem_value] = true
    end
  end
  config.stations[station].provides = provides

  -- scan for requests that conflict, remove 'em
  if config.stations[station].requests then
    for i = #config.stations[station].requests, 1, -1 do
      if provides[config.stations[station].requests[i].name] then
        table.remove(config.stations[station].requests, i)
      end
    end
  end

  -- tables are up to date, call for a refresh to bring the elements into line
  update_gui_item_selections(player, config_flow)
  entity.last_user = game.players[event.player_index]
end

-- function mapping for GUI element event handlers
local gui_change_handlers = {
  logistic_cargo_config_station_dropdown = function(event)
    local player = game.players[event.player_index]
    update_gui_item_selections(player, event.element.parent)
  end,
  logistic_cargo_config_request_button_1 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_2 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_3 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_4 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_5 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_6 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_7 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_8 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_9 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_10 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_11 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_button_12 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_1 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_2 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_3 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_4 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_5 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_6 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_7 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_8 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_9 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_10 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_11 = logistic_cargo_config_request_change,
  logistic_cargo_config_request_text_12 = logistic_cargo_config_request_change,
  logistic_cargo_config_provide_button_1 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_2 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_3 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_4 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_5 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_6 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_7 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_8 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_9 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_10 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_11 = logistic_cargo_config_provide_change,
  logistic_cargo_config_provide_button_12 = logistic_cargo_config_provide_change,
}

local function on_gui_event(event)
  if gui_change_handlers[event.element.name] then
    local player = game.players[event.player_index]
    if player.opened and player.opened.valid then
      if not global.wagons[player.opened.unit_number] then
        global.wagons[player.opened.unit_number] = {}
      end
      gui_change_handlers[event.element.name](event)
    else
      if player.gui.left.logistic_cargo_config then
        player.gui.left.logistic_cargo_config.destroy()
      end
    end
  end
end
script.on_event(defines.events.on_gui_selection_state_changed, on_gui_event)
script.on_event(defines.events.on_gui_text_changed, on_gui_event)
script.on_event(defines.events.on_gui_value_changed, on_gui_event)
script.on_event(defines.events.on_gui_elem_changed, on_gui_event)

-- copy config to rest of train
local function on_gui_click(event)
  if event.element.name == "logistic_cargo_config_copy_button" then
    local player = game.players[event.player_index]
    local entity = player.opened
    if entity and entity.valid then
      local source_config = global.wagons[entity.unit_number]
      for _, carriage in pairs(entity.train.cargo_wagons) do
        if carriage.name == "logistic-cargo-wagon" then
          local new_dest_settings = util.table.deepcopy(source_config)
          if global.wagons[carriage.unit_number] and global.wagons[carriage.unit_number].proxy then
            new_dest_settings.proxy = global.wagons[carriage.unit_number].proxy
          else
            new_dest_settings.proxy = nil
          end
          global.wagons[carriage.unit_number] = new_dest_settings
        end
      end
    else
      if player.gui.left.logistic_cargo_config then
        player.gui.left.logistic_cargo_config.destroy()
      end
    end
  end
end
script.on_event(defines.events.on_gui_click, on_gui_click)

local function on_init()
  global.wagons = {}
  global.active_proxies = {}
  global.active_wagons = {}
end
script.on_init(on_init)

local function on_load()
  if next(global.active_proxies) then
    script.on_nth_tick(15, check_active_proxies)
  end
end
script.on_load(on_load)
