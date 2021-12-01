function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.HandlesUndo = true
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "1.0"
    finaleplugin.Date = "November 27, 2021"
    return "RGP Lua Class Browser...", "RGP Lua Class Browser", "Explore the PDK Framework classes in RGP Lua."
end
    
local path = finenv.RunningLuaFolderPath
package.path = package.path .. ";" .. path.LuaString .. "/xml2lua/?.lua"

local create_class_index = function()
    local xml2lua = require("xml2lua")
    local handler = require("xmlhandler.tree")

    local jwhandler = handler:new()
    local jwparser = xml2lua.parser(jwhandler)
    -- parsing the xml croaks the debugger because of the size of the xml--don't try to debug it
    jwparser:parse(xml2lua.loadFile(path.LuaString .. "/jwluatagfile.xml"))

    local jwlua_compounds = jwhandler.root.tagfile.compound
    local temp_class_index = {}
    for i1, t1 in pairs(jwlua_compounds) do
        if t1._attr and t1._attr.kind == "class" then
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
        end
    end
    return temp_class_index
end

global_class_index = create_class_index()

require('mobdebug').start() -- uncomment this to debug (after creation of global_class_index because it takes forever in debugger to parse the xml)

local log_message = function(str, show_message)
    if (nil == show_message) then
        show_message = true
    end
    if show_message then
        print(str)
    end
end

eligible_classes = {}
for k, v in pairs(_G.finale) do
    local kstr = tostring(k)
    if kstr:find("FC") == 1  then
        eligible_classes[kstr] = 1
    end    
end

--global variables prevent garbage collection until script terminates

global_dialog = nil
global_dialog_info = {}     -- key: list control id or hard-coded string, value: table of associated data and controls
global_control_xref = {}    -- key: non-list control id, value: associated list control id

current_methods = {}
current_properties = {}
current_class_properties = {}
current_class_name = ""
changing_class_name_in_progress = false


local table_merge = function (t1, t2)
    for k, v in pairs(t2) do
        if nil == t1[k] then
            t1[k] = v
        end
    end 
    return t1
end

local get_edit_text = function(edit_control)
    if not edit_control then return "" end
    local str = finale.FCString()
    edit_control:GetText(str)
    return str.LuaString
end
    
local method_info = function(class_info, method_name)
    local rettype, args
    if class_info then
        local method = class_info.__members[method_name]
        if method then
            args = method.arglist
            rettype = method.type
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
        methods[k] = { class = classname, arglist = args, type = rettypes }
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
        class_methods[k] = { class = classname, arglist = args, type = rettypes }
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

local update_list = function(list_control, source_table, search_text)
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

local on_classname_changed = function(new_classname)
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
    end
    changing_class_name_in_progress = false
end

local on_class_selection = function(list_control, index)
    if index < 0 then
        on_classname_changed("")
        return
    end
    local fcstring = finale.FCString()
    list_control:GetItemText(index, fcstring)
    local str = fcstring.LuaString
    if str ~= current_class_name then
        on_classname_changed(str)
    end
end

local update_classlist = function(search_text)
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

pdk_framework_site = "https://robertgpatterson.com/-fininfo/-rgplua/pdkframework/"
local launch_docsite = function(html_file, anchor)
    if html_file then
        local url = pdk_framework_site .. html_file
        if anchor then
            -- add anchor to url here
        end
        if finenv.UI():IsOnWindows() then
            os.execute(string.format('start %s', url))
        else
            os.execute(string.format('open "%s"', url))
        end
        
    end
end

local create_dialog = function()
    local y = 0
    local vert_sep = 25
    local x = 0
    local col_width = 160
    local col_extra = 50
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
        local fcstring = finale.FCString()
        fcstring.LuaString = text
        static_text:SetWidth(this_col_width)
        static_text:SetText(fcstring)
        return static_text
    end
    
    local create_list = function(dialog, height, this_col_width, sel_func)
        local list = dialog:CreateListBox(x, y)
        list:SetWidth(this_col_width)
        list:SetHeight(height)
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
            fullname_label = nil,
            returns_label = nil,
            arglist_label = nil,
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
    
    local handle_edit_control = function(control)        
        local list_id = global_control_xref[search_text:GetControlID()]
        if nil == list_id then return end
        local list_info = global_dialog_info[list_id]
        if list_info then
            update_list(list_info.list_box, list_info.current_properties, get_edit_text(control))
        end
    end

    -- scratch FCString
    local str = finale.FCString()
    -- create a new dialog
    local dialog = finale.FCCustomLuaWindow()
    str.LuaString = "RGP Lua - Class Browser"
    dialog:SetTitle(str)
    dialog:RegisterInitWindow(update_classlist)
    dialog:RegisterHandleCommand(on_list_select)
    
    local classes_list = create_column(dialog, 400, col_width, "Classes:", on_class_selection,
        function(control)
            update_classlist(get_edit_text(control))
        end)
    global_control_xref["classes"] = classes_list:GetControlID()
    local class_doc = dialog:CreateButton(x, y)
    str.LuaString = "Class Documentation"
    class_doc:SetText(str)
    class_doc:SetWidth(col_width)
    dialog:RegisterHandleControlEvent(class_doc,
        function(control)
            local class_info = global_class_index[current_class_name]
            if class_info then
                launch_docsite(class_info.filename)
            end
        end
    )
    x = x + col_width + sep_width
    
    local properties_list = create_column(dialog, 150, col_width + col_extra, "Properties:", nil, handle_edit_control)
    global_control_xref["properties"] = properties_list:GetControlID()
    x = x + col_width + col_extra + sep_width
    
    methods_list = create_column(dialog, 150, col_width + col_extra, "Methods:", nil, handle_edit_control)
    global_control_xref["methods"] = methods_list:GetControlID()
    x = x + col_width + col_extra + sep_width
    
    local class_methods_list = create_column(dialog, 150, col_width + col_extra, "Class Methods:", nil)
    global_control_xref["class_methods"] = class_methods_list:GetControlID()
    
    -- create close button
    local ok_button = dialog:CreateOkButton()
    str.LuaString = "Close"
    ok_button:SetText(str)
    return dialog
end

local open_dialog = function()
    global_dialog = create_dialog()
    finenv.RegisterModelessDialog(global_dialog)
    global_dialog:ShowModeless()
end

open_dialog()

