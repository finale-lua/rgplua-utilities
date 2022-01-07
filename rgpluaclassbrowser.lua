function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.MinJWLuaVersion = 0.56
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "1.0"
    finaleplugin.Date = "November 27, 2021"
    return "RGP Lua Class Browser...", "RGP Lua Class Browser", "Explore the PDK Framework classes in RGP Lua."
end

package.path = package.path .. ";" .. finenv.RunningLuaFolderPath() .. "/xml2lua/?.lua"

--global variables prevent garbage collection until script terminates

eligible_classes = {}
global_class_index = nil
global_dialog = nil
global_dialog_info = {}     -- key: list control id or hard-coded string, value: table of associated data and controls
global_control_xref = {}    -- key: non-list control id, value: associated list control id
global_timer_id = 1         -- per docs, we supply the timer id, starting at 1
global_progress_label = nil

current_class_name = ""
changing_class_name_in_progress = false

function table_merge (t1, t2)
    for k, v in pairs(t2) do
        if nil == t1[k] then
            t1[k] = v
        end
    end 
    return t1
end

function get_edit_text(edit_control)
    if not edit_control then return "" end
    local fcstring = finale.FCString()
    edit_control:GetText(fcstring)
    return fcstring.LuaString
end

function set_text(control, text)
    if not control then return end
    local fcstring = finale.FCString()
    fcstring.LuaString = text
    control:SetText(fcstring)
end
    
function method_info(class_info, method_name)
    local rettype, args
    if class_info then
        local method = class_info.__members[method_name]
        if method then
            args = method.arglist:gsub(" override", "")
            rettype = method.type:gsub("virtual ", "")
            rettype = rettype:gsub("static ", "")
        end
    end
    return rettype, args
end

function get_properties_methods(classname)
    isparent = isparent or false
    local properties = {}
    local methods = {}
    local class_methods = {}
    local classtable = _G.finale[classname]
    if type(classtable) ~= "table" then return nil end
    local class_info = global_class_index[classname]
    for k, _ in pairs(classtable.__class) do
        local rettype, args = method_info(class_info, k)
        methods[k] = { class = classname, arglist = args, returns = rettype }
    end
    for k, _ in pairs(classtable.__propget) do
        properties[k] = { class = classname, readable = true, writeable = false }
    end
    for k, _ in pairs(classtable.__propset) do
        if nil == properties[k] then
            properties[k] = { class = classname, readable = false, writeable = true }
        else
            properties[k].writeable = true
        end
    end
    for k, _ in pairs(classtable.__static) do
        local rettype, args = method_info(class_info, k)
        class_methods[k] = { class = classname, arglist = args, returns = rettype }
    end
    for k, _ in pairs(classtable.__parent) do
        local parent_methods, parent_properties = get_properties_methods(k)
        if type(parent_methods) == "table" then
            methods = table_merge(methods, parent_methods)
        end
        if type(parent_properties) == "table" then
            properties = table_merge(properties, parent_properties)
        end
    end
    return methods, properties, class_methods
end

function update_list(list_control, source_table, search_text)
    list_control:Clear()
    local include_all = search_text == nil or search_text == ""
    local first_string = nil
    if type(source_table) == "table" then
        for k, v in pairsbykeys(source_table) do
            if include_all or k:find(search_text) == 1 then
                local fcstring = finale.FCString()
                fcstring.LuaString = k
                if type(v) == "table" then
                    if v.class ~= current_class_name then
                        fcstring.LuaString = fcstring.LuaString .. "  *"
                    end
                    if v.readable or v.writeable then
                        local str = "  ["
                        if v.readable then
                            str = str .. "R"
                            if v.writeable then
                                str = str .. "/W"
                            end
                        elseif v.writeable then
                            str = str .. "W"
                        end
                        str = str .. "]"
                        fcstring.LuaString = fcstring.LuaString .. str
                    end
                end
                list_control:AddString(fcstring)
                if first_string == nil then
                    first_string = k
                end
            end
        end
    end
    return first_string
end

local on_list_select = function(list_control)
    local list_info = global_dialog_info[list_control:GetControlID()]
    if list_info and list_info.selection_function and not list_info.in_progress then
        local selected_item = list_info.list_box:GetSelectedItem()
        if list_info.current_index ~= selected_item then
            list_info.in_progress = true
            list_info.current_index = selected_item
            list_info.selection_function(list_info.list_box, selected_item)
            list_info.in_progress = false
        end
    end
end

function on_classname_changed(new_classname)
    if changing_class_name_in_progress then return end
    changing_class_name_in_progress = true
    current_class_name = new_classname
    local current_methods, current_properties, current_class_methods = get_properties_methods(new_classname)
    global_dialog_info[global_control_xref["properties"]].current_strings = current_properties
    global_dialog_info[global_control_xref["methods"]].current_strings = current_methods
    global_dialog_info[global_control_xref["class_methods"]].current_strings = current_class_methods
    for k, v in pairs({"properties", "methods", "class_methods"}) do
        local list_info = global_dialog_info[global_control_xref[v]]
        update_list(list_info.list_box, list_info.current_strings, get_edit_text(list_info.search_text))
        if finenv.UI():IsOnWindows() then
            on_list_select(list_info.list_box)
        end
    end
    changing_class_name_in_progress = false
end

function on_class_selection(list_control, index)
    if index < 0 then
        on_classname_changed("")
        return
    end
    local str = get_plain_string(list_control, index)
    if str ~= current_class_name then
        on_classname_changed(str)
    end
end

function hide_show_display_area(list_info, show)
    list_info.fullname_static:SetVisible(show)
    list_info.returns_label:SetVisible(show)
    list_info.returns_static:SetVisible(show)
    list_info.method_doc_button:SetVisible(show)
    if list_info.arglist_static then
        list_info.arglist_label:SetVisible(show)
        list_info.arglist_static:SetVisible(show)
    end
end

function get_plain_string(list_control, index)
    local fcstring = finale.FCString()
    if index >= 0 then
        list_control:GetItemText(index, fcstring)
    end
    return string.match(fcstring.LuaString, "%S+")
end

function on_method_selection(list_control, index)
    local list_info = global_dialog_info[list_control:GetControlID()]
    local show = false
    if list_info and index >= 0 then
        local method_name = get_plain_string(list_control, index)
        if #method_name > 0 and list_info.current_strings then
            local method_info = list_info.current_strings[method_name]
            if method_info then
                local is_property = nil == method_info.arglist
                local dot = ":"
                if is_property then dot = "." end
                set_text(list_info.fullname_static, method_info.class .. dot .. method_name)
                if is_property then
                    local methods_list_info = global_dialog_info[global_control_xref["methods"]]
                    local property_getter_info = methods_list_info.current_strings["Get" .. method_name]
                    if property_getter_info then
                        set_text(list_info.returns_static, property_getter_info.returns)
                    end
                else
                    set_text(list_info.returns_static, method_info.returns)
                    set_text(list_info.arglist_static, method_info.arglist)
                end
                show = true
            end
        end
    end
    hide_show_display_area(list_info, show)
end

function update_classlist(search_text)
    if search_text == nil or search_text == "" then
        search_text = "FC"
    end
    local list_id = global_control_xref["classes"]
    if nil == list_id then return end
    local list_info = global_dialog_info[list_id]
    if list_info then
        local first_string = update_list(list_info.list_box, eligible_classes, search_text)
        if finenv.UI():IsOnWindows() then
            local index = list_info.list_box:GetSelectedItem()
            if index >= 0 then
                on_class_selection(list_info.list_box, index)
            else
                on_classname_changed("")
            end
        end
    end
end

pdk_framework_site = "https://robertgpatterson.com/-fininfo/-rgplua/pdkframework/"
function launch_docsite(html_file, anchor)
    if html_file then
        local url = pdk_framework_site .. html_file
        if anchor then
            url = url .. "#" .. anchor
        end
        if finenv.UI():IsOnWindows() then
            os.execute(string.format('start %s', url))
        else
            os.execute(string.format('open "%s"', url))
        end
        
    end
end

function on_doc_button(button_control)
    local list_info = global_dialog_info[global_control_xref[button_control:GetControlID()]]
    if list_info then
        local index = list_info.list_box:GetSelectedItem()
        local method_name = get_plain_string(list_info.list_box, index)
        if #method_name > 0 then
            local method_info = list_info.current_strings[method_name]
            if method_info then
                if nil == method_info.arglist then
                    method_name = "Get" .. method_name -- use property getter for properties
                end
                local class_info = global_class_index[method_info.class]
                if class_info then
                    local filename = class_info.filename
                    local anchor = nil
                    local method_metadata = class_info.__members[method_name]
                    if method_metadata then
                        anchor = method_metadata.anchor
                        if method_metadata.anchorfile then
                            filename = method_metadata.anchorfile
                        end
                    end
                    launch_docsite(filename, anchor)
                end
            end
        end
    end
end

get_eligible_classes = function()
    set_text(global_progress_label, "Getting eligible classes from Lua state...")
    local retval = {}
    for k, v in pairs(_G.finale) do
        local kstr = tostring(k)
        if kstr:find("FC") == 1  then
            retval[kstr] = 1
        end    
    end
    return retval
end

create_class_index = function()
    local xml2lua = require("xml2lua")
    local handler = require("xmlhandler.tree")

    set_text(global_progress_label, "Parsing xml for class and method info...")

    local counter = 0
    local jwhandler = handler:new()
    local org_text = jwhandler.text
    jwhandler.text = function(handler, text)
                if text:find("FC") == 1 or text:find("__FC") == 1 then
                    if (counter % 25) == 0 then
                        print("Parsing xml tags for " .. text .. "...")
                        set_text(global_progress_label, "Parsing xml tags for " .. text .. "...")
                        coroutine.yield()
                    end
                    counter = counter + 1
                end
                return org_text(handler, text)
            end
    local jwparser = xml2lua.parser(jwhandler)
    -- parsing the xml croaks the debugger because of the size of the xml--don't try to debug it
    jwparser:parse(xml2lua.loadFile(finenv.RunningLuaFolderPath() .. "/jwluatagfile.xml"))

    local jwlua_compounds = jwhandler.root.tagfile.compound
    local temp_class_index = {}
    for i1, t1 in pairs(jwlua_compounds) do
        if t1._attr and t1._attr.kind == "class" then
            set_text(global_progress_label, "Indexing " .. t1.name .. "...")
            temp_class_index[t1.name] = t1
            local members_index = {}
            if t1.member then
                if #t1.member <= 1 then
                    if t1.member._attr and t1.member._attr.kind == "function" then
                        members_index[t1.member.name] = t1.member
                    end
                elseif #t1.member > 1 then
                    for i2, t2 in pairs(t1.member) do
                        if t2._attr and t2._attr.kind == "function" then
                            members_index[t2.name] = t2
                        end
                    end
                end
            end
            temp_class_index[t1.name].__members = members_index
            coroutine.yield()
        end
    end
    return temp_class_index
end

coroutine_build_class_index = coroutine.create(function()
        eligible_classes = get_eligible_classes()
        coroutine.yield()
        global_class_index = create_class_index()
    end)

function on_timer(timer_id)
    if timer_id ~= global_timer_id then return end
    if not coroutine.resume(coroutine_build_class_index) then
        global_timer_id = 0 -- blocks further calls to this function
        global_dialog:StopTimer(timer_id)
        --require('mobdebug').start() -- uncomment this to debug (after creation of global_class_index because it takes forever in debugger to parse the xml)
        update_classlist()
        set_text(global_progress_label, "")
        global_progress_label:SetVisible(false)
    end
end

local create_dialog = function()
    local y = 0
    local vert_sep = 25
    local x = 0
    local col_width = 160
    local col_extra = 70
    local sep_width = 25
    
    local create_edit = function(dialog, this_col_width, search_func)
        local edit_text = dialog:CreateEdit(x, y)
        edit_text:SetWidth(this_col_width)
        if search_func then
            dialog:RegisterHandleControlEvent(edit_text, search_func)
        end
        
        return edit_text
    end
    
    local create_static = function(dialog, text, this_col_width)
        local static_text = dialog:CreateStatic(x, y)
        static_text:SetWidth(this_col_width)
        set_text(static_text, text)
        return static_text
    end
    
    local create_list = function(dialog, height, this_col_width, sel_func)
        local list = dialog:CreateListBox(x, y)
        list:SetWidth(this_col_width)
        list:SetHeight(height)
        if finenv.UI():IsOnMac() then
            list:UseAlternatingBackgroundRowColors(true)
        end
        return list
    end
    
    local create_column = function(dialog, height, width, static_text, sel_func, search_func)
        y = 0
        local edit_text = nil
        if search_func then
            edit_text = create_edit(dialog, width, search_func)
        end
        y = y + vert_sep
        create_static(dialog, static_text, width)
        y = y + vert_sep
        local list_control = create_list(dialog, height, width, sel_func)
        global_dialog_info[list_control:GetControlID()] =
        {
            list_box = list_control,
            search_text = edit_text,
            fullname_static = nil,
            returns_label = nil,
            returns_static = nil,
            arglist_label = nil,
            arglist_static = nil,
            method_doc_button = nil,
            selection_function = sel_func,
            current_index = -1,
            in_progress = false,
            current_strings = {}
        }
        if edit_text then
            global_control_xref[edit_text:GetControlID()] = list_control:GetControlID()
        end
        y = y + vert_sep/2 + height -- position y for adding more fields
        return list_control
    end
    
    local create_display_area = function(dialog, list_info, width, is_for_properties)
        is_for_properties = is_for_properties or false
        list_info.fullname_static = dialog:CreateStatic(x, y)
        list_info.fullname_static:SetWidth(width)
        list_info.fullname_static:SetVisible(false)
        local my_vert_sep = 15
        y = y + my_vert_sep + 5 -- more vert_sep for next info
        local my_x = x
        list_info.returns_label = dialog:CreateStatic(my_x, y)
        if is_for_properties then
            set_text(list_info.returns_label, "Type:")
        else
            set_text(list_info.returns_label, "Returns:")
        end
        local label_width = 35
        if not is_for_properties then
            label_width = 48
        end
        local doc_button_width = 40
        local my_x_sep = 1
        local return_static_width = width - label_width - doc_button_width - (2*my_x_sep)
        list_info.returns_label:SetWidth(label_width)
        list_info.returns_label:SetVisible(false)
        my_x = my_x + label_width + my_x_sep
        list_info.returns_static = dialog:CreateStatic(my_x, y)
        list_info.returns_static:SetWidth(return_static_width)
        list_info.returns_static:SetVisible(false)
        my_x = my_x + return_static_width + my_x_sep
        list_info.method_doc_button = dialog:CreateButton(my_x, y)
        list_info.method_doc_button:SetWidth(doc_button_width)
        list_info.method_doc_button:SetVisible(false)
        global_control_xref[list_info.method_doc_button:GetControlID()] = list_info.list_box:GetControlID()
        set_text(list_info.method_doc_button, "Doc.")
        list_info.method_doc_button:SetVisible(false)
        dialog:RegisterHandleControlEvent(list_info.method_doc_button, on_doc_button)
        if not is_for_properties then
            y = y + my_vert_sep
            my_x = x
            list_info.arglist_label = dialog:CreateStatic(my_x, y)
            set_text(list_info.arglist_label, "Params:")
            list_info.arglist_label:SetWidth(label_width)
            list_info.arglist_label:SetVisible(false)
            my_x = my_x + label_width + my_x_sep
            list_info.arglist_static = dialog:CreateStatic(my_x, y)
            list_info.arglist_static:SetWidth(width - doc_button_width - my_x + x)
            list_info.arglist_static:SetVisible(false)
        end
        y = y + vert_sep
    end
    
    local handle_edit_control = function(control)        
        local list_id = global_control_xref[control:GetControlID()]
        if nil == list_id then return end
        local list_info = global_dialog_info[list_id]
        if list_info then
            update_list(list_info.list_box, list_info.current_strings, get_edit_text(control))
        end
    end

    -- create a new dialog
    local dialog = finale.FCCustomLuaWindow()
    local str = finale.FCString() -- scratch
    str.LuaString = "RGP Lua - Class Browser"
    dialog:SetTitle(str)
    dialog:RegisterHandleCommand(on_list_select)
    --[[
    -- normally we would just use RegisterInitWindow to populate a modeless dialog,
    -- but this dialog takes a long time to process jwluatagfile.xml so we do it
    -- it in a timer handler allowing us to show progress. The UI is blocked while it happens,
    -- mainly because the xml has to be processed in one go.
    dialog:RegisterInitWindow(update_classlist)
    ]]
    dialog:RegisterInitWindow(
        function()
            global_dialog:SetTimer(global_timer_id, 1) -- timer can't be set until window is created
        end
    )
    dialog:RegisterHandleTimer(on_timer)
    
    local classes_list = create_column(dialog, 400, col_width, "Classes:", on_class_selection,
        function(control)
            update_classlist(get_edit_text(control))
        end)
    global_control_xref["classes"] = classes_list:GetControlID()
    local class_doc = dialog:CreateButton(x, y)
    set_text(class_doc, "Class Documentation")
    class_doc:SetWidth(col_width)
    dialog:RegisterHandleControlEvent(class_doc,
        function(control)
            local class_info = global_class_index[current_class_name]
            if class_info then
                launch_docsite(class_info.filename)
            end
        end
    )
    local bottom_y = y
    x = x + col_width + sep_width
    global_progress_label = dialog:CreateStatic(x, bottom_y)
    global_progress_label:SetWidth(2.5*col_width)
    --macOS does not update label text in real time, but Windows does.
    --Therefore on macOS this is the only text that shows in the label
    set_text(global_progress_label, "initializing...")
    
    local properties_list = create_column(dialog, 170, col_width + col_extra, "Properties:", on_method_selection, handle_edit_control)
    global_control_xref["properties"] = properties_list:GetControlID()
    create_display_area (dialog, global_dialog_info[properties_list:GetControlID()], col_width + col_extra, true)
    x = x + col_width + col_extra + sep_width
    
    local methods_list = create_column(dialog, 170, col_width + col_extra, "Methods:", on_method_selection, handle_edit_control)
    global_control_xref["methods"] = methods_list:GetControlID()
    create_display_area (dialog, global_dialog_info[methods_list:GetControlID()], col_width + col_extra)
    x = x + col_width + col_extra + sep_width
    
    local class_methods_list = create_column(dialog, 170, col_width + col_extra, "Class Methods:", on_method_selection)
    global_control_xref["class_methods"] = class_methods_list:GetControlID()
    create_display_area (dialog, global_dialog_info[class_methods_list:GetControlID()], col_width + col_extra)
    x = x + col_width + col_extra
    
    -- create close button
    local close_button = dialog:CreateCloseButton(x-70, bottom_y)
    close_button:SetWidth(70)
    set_text(close_button, "Close")
    return dialog
end

local open_dialog = function()
    global_dialog = create_dialog()
    finenv.RegisterModelessDialog(global_dialog)
    global_dialog:ShowModeless()
end

open_dialog()
