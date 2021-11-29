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
    return "RGP Lua Class Browser", "RGP Lua Class Browser", "RGP Lua Class Browser"
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

local table_merge = function (t1, t2)
   for k,v in pairs(t2) do
       t1[k] = v
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
        for k, _ in pairsbykeys(source_table) do
            if include_all or k:find(search_text) == 1 then
                local fcstring = finale.FCString()
                fcstring.LuaString = k;
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
    current_methods, current_properties, current_class_methods = get_properties_methods(new_classname)
    update_list(properties_list, current_properties, get_edit_text(search_properties_text))
    update_list(methods_list, current_methods, get_edit_text(search_methods_text))
    update_list(class_methods_list, current_class_methods, "")
end

local update_classlist = function(search_text)
    if search_text == nil or search_text == "" then
        search_text = "FC"
    end
    local first_string = update_list(classes_list, eligible_classes, search_text)
    -- for debugging
    local index = classes_list:GetSelectedLine()
    if index >= 0 then
        local str = finale.FCString()
        classes_list:GetItemText(index, str)
        on_classname_changed(str.LuaString)
    elseif first_string then
        on_classname_changed(first_string)
    end
end

local create_dialog = function()
    local x = 0
    local y = 0
    local col_width = 160
    local sep_width = 30
    local vert_sep = 25
    
    local create_edit = function(dialog)
        local edit_text = dialog:CreateEdit(x, y)
        edit_text:SetWidth(col_width)
        x = x + col_width + sep_width
        return edit_text
    end
    
    local create_static = function(dialog, text)
        local static_text = dialog:CreateStatic(x, y)
        local fcstring = finale.FCString()
        fcstring.LuaString = text
        static_text:SetWidth(col_width)
        static_text:SetText(fcstring)
        x = x + col_width + sep_width
        return static_text
    end
    
    local create_list = function(dialog, height)
        local list = dialog:CreateListBox(x, y)
        list:SetWidth(col_width)
        list:SetHeight(height)
        x = x + col_width + sep_width
        return list
    end

    -- scratch FCString
    local str = finale.FCString()
    -- create a new dialog
    local dialog = finale.FCCustomLuaWindow()
    str.LuaString = "RGP Lua - Class Browser"
    dialog:SetTitle(str)
    
    -- create search fields
    search_classes_text = create_edit(dialog)
    dialog:RegisterHandleControlEvent(
        search_classes_text,
        function(control)
            update_classlist(get_edit_text(control))
        end
    )
    
    search_properties_text = create_edit(dialog)
    search_methods_text = create_edit(dialog)
    
    -- create headers
    x = 0
    y = y + vert_sep
    create_static(dialog, "Classes:")
    create_static(dialog, "Properties:")
    create_static(dialog, "Methods:")
    create_static(dialog, "Class Methods:")
    
    -- create lists
    x = 0
    y = y + vert_sep
    classes_list = create_list(dialog, 400)
    properties_list = create_list(dialog, 150)
    methods_list = create_list(dialog, 150)
    class_methods_list = create_list(dialog, 150)
    
    -- create close button
    local ok_button = dialog:CreateOkButton()
    str.LuaString = "Close"
    ok_button:SetText(str)
    return dialog
end

local open_dialog = function()
    local dialog = create_dialog()
    update_classlist()
    finenv.RegisterModelessDialog(dialog)
    dialog:ShowModeless()
end

open_dialog()

