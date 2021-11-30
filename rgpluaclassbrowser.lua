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

require('mobdebug').start() -- uncomment this to debug

eligible_classes = {}
for k, v in pairs(_G.finale) do
    local kstr = tostring(k)
    if kstr:find("FC") == 1  then
        eligible_classes[kstr] = 1
    end    
end

search_classes_text = nil
search_properties_text = nil
search_methods_text = nil

classes_list = nil
properties_list = nil
methods_list = nil
class_methods_list = nil

current_methods = {}
current_properties = {}
current_class_properties = {}
current_class_name = ""

selection_funcs = {}

local table_merge = function (t1, t2)
    for k, v in pairs(t2) do
        if nil == t1[k] then
            t1[k] = v
        end
    end 
    return t1
end

local get_edit_text = function(edit_control)
    local str = finale.FCString()
    edit_control:GetText(str)
    return str.LuaString
end


function get_properties_methods(classname)
    isparent = isparent or false
    local properties = {}
    local methods = {}
    local class_methods = {}
    local classtable = _G.finale[classname]
    if type(classtable) ~= "table" then return nil end
    for k, _ in pairs(classtable.__class) do
        methods[k] = { class = classname } -- ToDo: eventually maybe this also includes a return value and signature from xml or elsewhere
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
        class_methods[k] = { class = classname }
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
                fcstring.LuaString = k;
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
    current_class_name = new_classname
    current_methods, current_properties, current_class_methods = get_properties_methods(new_classname)
    update_list(properties_list, current_properties, get_edit_text(search_properties_text))
    update_list(methods_list, current_methods, get_edit_text(search_methods_text))
    update_list(class_methods_list, current_class_methods, "")
end

local on_class_selection = function(list_control, index)
    if index < 0 then
        if list_control:GetCount() <= 0 then return end
        index = 0
    end
    local str = finale.FCString()
    list_control:GetItemText(index, str)
    on_classname_changed(str.LuaString)
end

local update_classlist = function(search_text)
    if search_text == nil or search_text == "" then
        search_text = "FC"
    end
    local first_string = update_list(classes_list, eligible_classes, search_text)
    -- for debugging
    local index = classes_list:GetSelectedItem()
    if index >= 0 then
        on_class_selection(classes_list, index)
    elseif first_string then
        on_classname_changed(first_string)
    end
end

local on_list_select = function(list_control)
    local list_info = selection_funcs[list_control:GetControlID()]
    if list_info and list_info.selection_function then
        --print(list_control:ClassName() .. " " .. tostring(list_control:GetControlID()))
        local selected_item = list_info.list_box:GetSelectedItem()
        if list_info.current_index ~= selected_item then
            list_info.current_index = selected_item
            list_info.selection_function(list_info.list_box, selected_item)
        end
    end
end

local create_dialog = function()
    local x = 0
    local y = 0
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
        selection_funcs[list:GetControlID()] = { list_box = list, selection_function = sel_func, current_index = -1 }
        return list
    end
    
    local create_column = function(dialog, height, width, static_text, sel_func, search_func)
        y = 0
        local vert_sep = 25
        local edit_text = nil
        if search_func then
            edit_text = create_edit(dialog, width, search_func)
        end
        y = y + vert_sep
        create_static(dialog, static_text, width)
        y = y + vert_sep
        local list_control = create_list(dialog, height, width, sel_func)
        x = x + width + sep_width
        return list_control, edit_text
    end

    -- scratch FCString
    local str = finale.FCString()
    -- create a new dialog
    local dialog = finale.FCCustomLuaWindow()
    str.LuaString = "RGP Lua - Class Browser"
    dialog:SetTitle(str)
    dialog:RegisterInitWindow(update_classlist)
    dialog:RegisterHandleCommand(on_list_select)
    
    classes_list, search_classes_text = create_column(dialog, 400, col_width, "Classes:", on_class_selection,
        function(control)
            print("Enter edit text function")
            update_classlist(get_edit_text(control))
            print("Exit edit text function")
        end)
    properties_list, search_properties_text = create_column(dialog, 150, col_width + col_extra, "Properties:", nil,
        function(control)
            update_list(properties_list, current_properties, get_edit_text(control))
        end)
    methods_list, search_methods_text = create_column(dialog, 150, col_width + col_extra, "Methods:", nil,
        function(control)
                update_list(methods_list, current_methods, get_edit_text(control))
        end)
    class_methods_list = create_column(dialog, 150, col_width + col_extra, "Class Methods:", nil)
    
    -- create close button
    local ok_button = dialog:CreateOkButton()
    str.LuaString = "Close"
    ok_button:SetText(str)
    return dialog
end

local open_dialog = function()
    local dialog = create_dialog()
    finenv.RegisterModelessDialog(dialog)
    dialog:ShowModeless()
end

open_dialog()

